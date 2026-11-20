import { EntityType, textProcessing } from '@kit.NaturalLanguageKit'

export interface CaptureEntities {
  body: string
  scheduled: string | null
}

interface RecognizedTime {
  start?: string
  suggestStart?: string
  isContainFuzzyTime?: boolean
  isIllegal?: boolean
  isChangedIllegal?: boolean
}

interface EntityDetails extends RecognizedTime {
  time?: RecognizedTime[]
}

function emptyEntities(): CaptureEntities { return { body: '', scheduled: null } }

// 只转换平台已经归一化的日期，不在宿主解释“明天”等自然语言。
function scheduledTimestamp(value: string, fuzzy: boolean): string | null {
  const parts = /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2}))?|T[A-Z]+)?$/.exec(value)
  if (!parts) return null
  const year = Number(parts[1]), month = Number(parts[2]), day = Number(parts[3])
  const date = new Date(Date.UTC(year, month - 1, day))
  if (year < 1000 || date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return null
  if (parts[4] && (Number(parts[4]) > 23 || Number(parts[5]) > 59 || Number(parts[6] || '0') > 59)) return null
  const time = !fuzzy && parts[4] ? ` ${parts[4]}:${parts[5]}` : ''
  return `<${parts[1]}-${parts[2]}-${parts[3]}${time}>`
}

function entitySchedule(entity: textProcessing.Entity): string | null {
  try {
    const details = JSON.parse(entity.jsonObject) as EntityDetails
    if (!details) return null
    // 真机返回直接时间对象；部分版本的文档结构使用 time 数组。
    const times: RecognizedTime[] = Array.isArray(details.time) ? details.time : [details]
    for (const time of times) {
      if (!time || time.isIllegal || time.isChangedIllegal) continue
      for (const value of [time.suggestStart, time.start]) {
        if (typeof value !== 'string') continue
        const scheduled = scheduledTimestamp(value, time.isContainFuzzyTime === true)
        if (scheduled) return scheduled
      }
    }
  } catch (_) { /* 单个实体损坏不影响其他时间或地址。 */ }
  return null
}

// 地址协议的 URI 保留可读的 Unicode 文本；仅转义会改变 Org 链接边界或
// 被 decodeURIComponent 误解释的字符。这样生成的正文仍是可直接阅读的地址。
function addressUri(address: string): string {
  return Array.from(address).map((character: string): string => {
    const code = character.codePointAt(0) ?? 0
    if (code <= 0x1f || code === 0x7f || character === '[' || character === ']' || character === '%') {
      return encodeURIComponent(character)
    }
    return character
  }).join('')
}

function captureEntities(entities: textProcessing.Entity[]): CaptureEntities {
  const addresses: string[] = []
  let scheduled: string | null = null
  for (const entity of entities.slice().sort((left: textProcessing.Entity, right: textProcessing.Entity): number => left.charOffset - right.charOffset)) {
    if (entity.type === EntityType.LOCATION) {
      const address = entity.text.replace(/[\r\n\t]+/g, ' ').trim()
      if (address && !addresses.includes(address)) addresses.push(address)
    } else if (entity.type === EntityType.DATETIME && scheduled === null) {
      scheduled = entitySchedule(entity)
    }
  }
  const links = addresses.map((address: string): string => {
    const label = address.replace(/\[/g, '［').replace(/\]/g, '］')
    return `[[addr:${addressUri(address)}][${label}]]`
  })
  return { body: links.join('\n'), scheduled }
}

const RECOGNITION_TIMEOUT_MS = 3000
// 下一次识别必须等当前引擎实际释放，即使录入已因超时继续保存。
let activeRecognition: Promise<void> | undefined

export class CaptureEntityService {
  static async recognize(title: string): Promise<CaptureEntities> {
    if (!title.trim() || title.length > 1000 || !canIUse('SystemCapability.AI.NaturalLanguage.TextProcessing')) return emptyEntities()
    let entities = emptyEntities()
    let timedOut = false
    let timer = -1
    const deadline = new Promise<void>((resolve): void => {
      timer = setTimeout((): void => { timedOut = true; resolve() }, RECOGNITION_TIMEOUT_MS)
    })
    const recognizeAndRelease = async (): Promise<void> => {
      try {
        const result = await textProcessing.getEntity(title, {
          entityTypes: [EntityType.LOCATION, EntityType.DATETIME]
        })
        if (!timedOut) entities = captureEntities(result)
      } catch (_) {
        // 服务异常时按原始标题保存。
      } finally {
        try { await textProcessing.release() } catch (_) { /* 保留已取得的识别结果。 */ }
      }
    }
    try {
      while (activeRecognition) {
        await Promise.race([activeRecognition, deadline])
        if (timedOut) return entities
      }
      const work = recognizeAndRelease().finally((): void => { activeRecognition = undefined })
      activeRecognition = work
      await Promise.race([work, deadline])
      return entities
    } finally {
      clearTimeout(timer)
    }
  }
}
