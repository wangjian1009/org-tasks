import { localizedText } from '../ui/LocalizedText'
import { Context } from '@kit.AbilityKit'
import { AppConfigService } from './AppConfigService'
import { TrashService } from './TrashService'
import { FileTargetService } from './FileTargetService'
import { CoreTask, CoreTaskModification, CoreTaskOperation, NativeCoreService } from './NativeCoreService'

// 宿主仅组装操作与版本约束；标题定位、保真写入和上传意图均由 Core 处理。
export class NoteService {
  static async createMemo(context: Context, title: string, body: string): Promise<void> {
    if (!title.trim()) throw new Error(localizedText($r('app.string.text_title_cannot_be_empty')))
    const config = await AppConfigService.load(context, false)
    const target = await FileTargetService.resolve(config, 'memo')
    if (!target) throw new Error(localizedText($r('app.string.text_the_memo_file_is_not_selected_or')))
    const file = await target.repo.file(target.path)
    await NativeCoreService.executeTaskOperations(config.repos, {
      operations: [{ type: 'Creation', data: { position: { parent: file.fullPath }, title, body,
        state: null } }],
      fileVersions: [{ repoId: target.repo.id, file: target.path, version: file.fileVersion }]
    }, config.todoDefaults, config.coreSettings)
  }

  static async update(context: Context, note: CoreTask, title: string, body: string): Promise<void> {
    if (!title.trim()) throw new Error(localizedText($r('app.string.text_title_cannot_be_empty')))
    const modifications: CoreTaskModification[] = []
    if (title !== note.heading) modifications.push({ field: 'TITLE', value: title })
    if (body !== note.body) modifications.push({ field: 'BODY', value: body })
    if (modifications.length === 0) return
    await NoteService.execute(context, note, { type: 'Modification', data: { path: note.fullPath, modifications } })
  }

  static async remove(context: Context, note: CoreTask): Promise<void> {
    if (note.repoId === '<preview>') await NoteService.execute(context, note, { type: 'Deletion', data: { path: note.fullPath } })
    else await TrashService.perform(context, [note], 'trash')
  }

  static async modify(context: Context, note: CoreTask, modifications: CoreTaskModification[]): Promise<void> {
    await NoteService.execute(context, note, { type: 'Modification', data: { path: note.fullPath, modifications } })
  }

  private static async execute(context: Context, note: CoreTask, operation: CoreTaskOperation): Promise<void> {
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    if (note.repoId === '<preview>') {
      await workspace.executeTaskOperations({ operations: [operation],
        fileVersions: [{ repoId: note.repoId, file: note.filePath, version: note.fileVersion }] })
      return
    }
    const repo = (await workspace.repos()).find(item => item.id === note.repoId)
    const repository = config.repos.find(item => item.rootDirectory === repo?.rootDirectory)
    if (!repository) throw new Error(localizedText($r('app.string.text_target_repository_not_available')))
    await workspace.executeTaskOperations({
      operations: [operation],
      fileVersions: [{ repoId: note.repoId, file: note.filePath, version: note.fileVersion }]
    })
  }
}
