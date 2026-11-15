import { Context } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { CachedDataSet } from './PageDataSnapshot'

interface PageCacheEnvelope { formatVersion: number; pageName: string; scope: string; savedAt: number; dataSets: CachedDataSet[] }

// 每页一个文件，所有数据集同次写入；数据载荷 JSON 只解析一次，不另行序列化为字符串。
export type CacheWriteResult = 'written' | 'deferred' | 'superseded'
export class PageDataCache {
  private static queues: Map<string, Promise<CacheWriteResult>> = new Map()
  private static owners: Map<string, number> = new Map()
  private static nextOwner: number = 1
  private readonly directory: string
  private readonly path: string
  private readonly owner: number
  private readonly pageName: string
  private readonly scope: string

  constructor(context: Context, pageName: string, scope: string) {
    if (!pageName.trim() || pageName === '.' || pageName === '..' || /[/\\\x00]/.test(pageName) ||
      new util.TextEncoder().encodeInto(pageName).length > 160) throw new Error('页面缓存名称无效')
    this.directory = `${context.filesDir}/page-data/v1`
    this.path = `${this.directory}/${pageName}.json`
    this.pageName = pageName
    this.scope = scope
    this.owner = PageDataCache.nextOwner++
    PageDataCache.owners.set(this.path, this.owner)
  }

  async read(): Promise<CachedDataSet[] | undefined> {
    try {
      if (!await fs.access(this.path)) return undefined
      const size = (await fs.stat(this.path)).size
      if (size > 32 * 1024 * 1024) return undefined
      const envelope = JSON.parse(await fs.readText(this.path)) as PageCacheEnvelope
      if (envelope.formatVersion !== 1 || envelope.pageName !== this.pageName || envelope.scope !== this.scope || !Array.isArray(envelope.dataSets)) return undefined
      return envelope.dataSets
    } catch (error) { throw error as Error }
  }

  write(dataSets: CachedDataSet[], canCommit: () => boolean = (): boolean => true): Promise<CacheWriteResult> {
    const envelope: PageCacheEnvelope = { formatVersion: 1, pageName: this.pageName, scope: this.scope, savedAt: Date.now(), dataSets }
    const previous = PageDataCache.queues.get(this.path) ?? Promise.resolve<CacheWriteResult>('superseded')
    const next = previous.catch((): CacheWriteResult => 'deferred').then(async (): Promise<CacheWriteResult> => {
      if (PageDataCache.owners.get(this.path) !== this.owner) return 'superseded'
      try { await fs.mkdir(this.directory, true) }
      catch (error) { if (!(await fs.stat(this.directory)).isDirectory()) throw error as Error }
      const bytes = new util.TextEncoder().encodeInto(JSON.stringify(envelope))
      if (bytes.length > 32 * 1024 * 1024) throw new Error('页面缓存超过大小限制')
      const temporary = `${this.path}.${util.generateRandomUUID()}.tmp`
      try {
        const file = await fs.open(temporary, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
        try {
          let offset = 0
          while (offset < bytes.length) {
            const written = await fs.write(file.fd, bytes.slice(offset).buffer)
            if (written <= 0 || written > bytes.length - offset) throw new Error('页面缓存未完整写入')
            offset += written
          }
          await fs.fsync(file.fd)
        } finally { await fs.close(file) }
        if (PageDataCache.owners.get(this.path) !== this.owner) return 'superseded'
        if (!canCommit()) return 'deferred'
        await fs.rename(temporary, this.path)
        return 'written'
      } finally { try { await fs.unlink(temporary) } catch (_) {} }
    })
    PageDataCache.queues.set(this.path, next)
    next.then((): void => { if (PageDataCache.queues.get(this.path) === next) PageDataCache.queues.delete(this.path) },
      (): void => { if (PageDataCache.queues.get(this.path) === next) PageDataCache.queues.delete(this.path) })
    return next
  }
}
