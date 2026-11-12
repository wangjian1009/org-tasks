import { TaskStateCategory } from '../ui/TaskStatePresentation'
import { Context } from '@kit.AbilityKit'
import { AppConfig, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { NativeCoreService } from './NativeCoreService'
import { FileTargetService, fileTargetRepository } from './FileTargetService'
import { CaptureEntityService } from './CaptureEntityService'
import { DeviceBadgeService } from './DeviceBadgeService'

import { CaptureDraft, CaptureDraftStore } from './CaptureDraftStore'

export function captureRepository(config: AppConfig): RepoConfig | undefined {
  return fileTargetRepository(config, 'inbox')
}

export class CaptureService {
  static async prepare(context: Context): Promise<void> {
    const config = await AppConfigService.load(context, false)
    await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
  }

  static drafts(context: Context): Promise<CaptureDraft[]> { return CaptureDraftStore.drafts(context) }
  static putDraft(context: Context, draft: CaptureDraft): Promise<void> { return CaptureDraftStore.putDraft(context, draft) }
  static removeDraft(context: Context, id: string): Promise<void> { return CaptureDraftStore.removeDraft(context, id) }

  static async save(context: Context, title: string): Promise<void> {
    if (!title.trim()) throw new Error('请输入标题')
    const normalizedTitle = title.trim()
    const entities = await CaptureEntityService.recognize(normalizedTitle)
    const config = await AppConfigService.load(context, false)
    const target = await FileTargetService.resolve(config, 'inbox')
    if (!target) throw new Error('收件箱文件未选择或已失效，请在设置中重新选择')
    const file = await target.repo.file(target.path)
    const state = target.metadata.taskStateOf(TaskStateCategory.Todo)
    if (!state) throw new Error('目标文件没有可用的未完成状态，请检查 TODO 设置')
    await NativeCoreService.executeTaskOperations(config.repos, {
      operations: [{ type: 'Creation', data: { position: { parent: file.fullPath }, title: normalizedTitle,
        body: entities.body, scheduled: entities.scheduled, state: state.name } }],
      queueRepoIds: target.repository.webdavEnabled ? [target.repo.id] : [],
      fileVersions: [{ repoId: target.repo.id, file: target.path, version: file.fileVersion }]
    }, config.todoDefaults, config.coreSettings)
    await DeviceBadgeService.refresh(context)
  }
}
