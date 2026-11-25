import { localizedText } from '../ui/LocalizedText'
import { TaskStateCategory } from '../ui/TaskStatePresentation'
import { Context } from '@kit.AbilityKit'
import { AppConfig, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { CoreTaskOperationGroup, NativeCoreService } from './NativeCoreService'
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

  static async save(context: Context, title: string, operationId?: string): Promise<void> {
    if (!title.trim()) throw new Error(localizedText($r('app.string.text_please_enter_the_title')))
    const normalizedTitle = title.trim()
    const entities = await CaptureEntityService.recognize(normalizedTitle)
    const config = await AppConfigService.load(context, false)
    const target = await FileTargetService.resolve(config, 'inbox')
    if (!target) throw new Error(localizedText($r('app.string.text_inbox_file_not_selected_or_expired_re')))
    const file = await target.repo.file(target.path)
    const state = target.metadata.taskStateOf(TaskStateCategory.Todo)
    if (!state) throw new Error(localizedText($r('app.string.text_target_file_is_not_available_for_uncompleted')))
    const group: CoreTaskOperationGroup = {
      operations: [{ type: 'Creation', data: { position: { parent: file.fullPath }, title: normalizedTitle,
        body: entities.body, scheduled: entities.scheduled, state: state.name } }],
      fileVersions: [{ repoId: target.repo.id, file: target.path, version: file.fileVersion }]
    }
    if (operationId) group.operationId = operationId
    await NativeCoreService.executeTaskOperations(config.repos, group, config.todoDefaults, config.coreSettings)
    // 角标可能等待数据集写入队列清空，须独立于捕捉提交。
    Promise.resolve().then((): Promise<void> => DeviceBadgeService.refresh(context))
      .catch((): void => { console.error('捕捉后更新设备提示计数失败') })
  }
}
