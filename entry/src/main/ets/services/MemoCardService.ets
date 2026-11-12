import { Context, Want } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { formInfo } from '@kit.FormKit'
import { AppConfigService } from './AppConfigService'
import { fileTargetRepository, FileTargetService } from './FileTargetService'
import { CoreTask, NativeCoreService, taskResult, fileResult } from './NativeCoreService'
import { PreferencesStore } from './PreferencesStore'
import { memoRecordQuery } from './TaskViewQueries'
import { taskTagOptions } from '../ui/TaskTagFilterPresentation'

export interface MemoCardData {
  memoCardTitle: string
  memoCardItem1: string
  memoCardItem2: string
  memoCardItem3: string
  memoCardItemId1: string
  memoCardItemId2: string
  memoCardItemId3: string
  memoCardMessage: string
}

export interface MemoCardSnapshot {
  data: MemoCardData
  tags: string[]
  available: boolean
}

export function memoCardData(tasks: CoreTask[] = [], tag: string = '', message: string = ''): MemoCardData {
  const items = tasks.filter((task: CoreTask): boolean => task.heading.trim().length > 0).slice(0, 3)
  return {
    memoCardTitle: tag || '全部备忘',
    memoCardItem1: items[0]?.heading.trim() ?? '', memoCardItem2: items[1]?.heading.trim() ?? '',
    memoCardItem3: items[2]?.heading.trim() ?? '',
    memoCardItemId1: items[0]?.id ?? '', memoCardItemId2: items[1]?.id ?? '', memoCardItemId3: items[2]?.id ?? '',
    memoCardMessage: message || (tag ? '此标签下暂无备忘' : '暂无备忘')
  }
}

export function memoCardFormId(want: Want): string {
  const value = want.parameters?.[formInfo.FormParam.IDENTITY_KEY]
  return typeof value === 'string' && /^[0-9]{1,20}$/.test(value) && value !== '0' ? value : ''
}

function settingsName(formId: string): string {
  if (!/^[0-9]{1,20}$/.test(formId) || formId === '0') throw new Error('无法识别此卡片，请从桌面长按卡片进入编辑')
  return `org_tasks_memo_card_${formId}`
}

// 每个实例使用独立存储，扩展进程重新读取配置；筛选与排序交给 Core。
export class MemoCardService {
  static async loadTag(context: Context, formId: string): Promise<string> {
    const name = settingsName(formId)
    await preferences.removePreferencesFromCache(context, name)
    const store = await PreferencesStore.open(context, name)
    const tag = await store.get('tag', '')
    if (typeof tag !== 'string') throw new Error('卡片标签设置无效，请重新选择')
    return tag
  }

  static async saveTag(context: Context, formId: string, tag: string): Promise<void> {
    const name = settingsName(formId)
    await preferences.removePreferencesFromCache(context, name)
    const store = await PreferencesStore.open(context, name)
    await store.put('tag', tag)
    await store.flush()
  }

  static async remove(context: Context, formId: string): Promise<void> {
    await preferences.deletePreferences(context, settingsName(formId))
  }

  static async snapshot(context: Context, tag: string): Promise<MemoCardSnapshot> {
    const config = await AppConfigService.load(context, false)
    if (!fileTargetRepository(config, 'memo')) {
      return { data: memoCardData([], tag, '请先在应用中选择备忘文件'), tags: [], available: false }
    }
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const target = FileTargetService.prepare(config, await workspace.repos(), 'memo')
    if (!target) return { data: memoCardData([], tag, '备忘文件已失效，请在应用中重新选择'), tags: [], available: false }
    const results = await workspace.query([{ type: 'task', repoIds: [target.reference.repoId],
      query: memoRecordQuery(target.reference.path, tag) }, target.file])
    const metadata = fileResult(results[1])[0]
    if (!metadata) return { data: memoCardData([], tag, '备忘文件已失效，请在应用中重新选择'), tags: [], available: false }
    const result = taskResult(results[0])
    return { data: memoCardData(result.tasks, tag), tags: taskTagOptions(result.tasks, metadata.tagOptions), available: true }
  }
}
