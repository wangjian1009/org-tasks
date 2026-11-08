import { Context } from '@kit.AbilityKit'
import { AppConfig, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { NativeCoreService } from './NativeCoreService'
import { FileTargetService, fileTargetRepository } from './FileTargetService'

import { CaptureDraft, CaptureDraftStore } from './CaptureDraftStore'

export function captureRepository(config: AppConfig): RepoConfig | undefined {
  return fileTargetRepository(config, 'inbox')
}

export class CaptureService {
  static async prepare(context: Context): Promise<void> {
    const config = await AppConfigService.load(context, false)
    await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
  }

  static drafts(context: Context): Promise<CaptureDraft[]> { return CaptureDraftStore.drafts(context) }
  static putDraft(context: Context, draft: CaptureDraft): Promise<void> { return CaptureDraftStore.putDraft(context, draft) }
  static removeDraft(context: Context, id: string): Promise<void> { return CaptureDraftStore.removeDraft(context, id) }

  static async save(context: Context, title: string): Promise<void> {
    if (!title.trim()) throw new Error('请输入标题')
    const config = await AppConfigService.load(context, false)
    const target = await FileTargetService.resolve(config, 'inbox')
    if (!target) throw new Error('收件箱文件未选择或已失效，请在设置中重新选择')
    await target.repo.createTask(target.path,
      { heading: title.trim(), scheduled: '', deadline: '', tags: [], priority: '', recordCreated: true },
      target.repository.webdavEnabled, true)
  }
}
