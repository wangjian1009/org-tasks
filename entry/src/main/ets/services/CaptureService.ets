import { Context } from '@kit.AbilityKit'
import { AppConfig, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { NativeCoreService } from './NativeCoreService'

import { CaptureDraft, CaptureDraftStore } from './CaptureDraftStore'

export function captureRepository(config: AppConfig): RepoConfig | undefined {
  if (config.captureRepoId) return config.repos.find((repo: RepoConfig) => repo.id === config.captureRepoId)
  return config.repos.length === 1 ? config.repos[0] : undefined
}

export class CaptureService {
  static async prepare(context: Context): Promise<void> {
    const config = await AppConfigService.load(context, false)
    await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
  }

  static drafts(context: Context): Promise<CaptureDraft[]> { return CaptureDraftStore.drafts(context) }
  static putDraft(context: Context, draft: CaptureDraft): Promise<void> { return CaptureDraftStore.putDraft(context, draft) }
  static removeDraft(context: Context, id: string): Promise<void> { return CaptureDraftStore.removeDraft(context, id) }

  static async selectRepository(context: Context, id: string): Promise<void> {
    const config = await AppConfigService.load(context)
    if (!config.repos.some((repo: RepoConfig) => repo.id === id)) throw new Error('目标存储库已被移除')
    config.captureRepoId = id
    await AppConfigService.save(context, config)
  }

  static async save(context: Context, title: string): Promise<void> {
    if (!title.trim()) throw new Error('请输入标题')
    const config = await AppConfigService.load(context, false)
    const repository = captureRepository(config)
    if (!repository) throw new Error('请先选择快速捕捉的默认存储库')
    if (!config.inboxFile) throw new Error('请先配置收件箱文件')
    await NativeCoreService.createTask(config.repos, repository, config.inboxFile,
      { heading: title.trim(), scheduled: '', deadline: '', tags: [], priority: '' }, config.todoDefaults)
  }
}
