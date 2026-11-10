import { Context } from '@kit.AbilityKit'
import { AppConfigService } from './AppConfigService'
import { CoreTask, CoreTaskModification, NativeCoreService } from './NativeCoreService'

// 只组装字段操作和快照版本；保真修改、校验与通知由 Core 完成。
export class TaskInlineService {
  static async modify(context: Context, task: CoreTask, modifications: CoreTaskModification[]): Promise<void> {
    if (modifications.length === 0) return
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
    const repo = (await workspace.repos()).find(item => item.id === task.repoId)
    const repository = config.repos.find(item => item.rootDirectory === repo?.rootDirectory)
    if (!repository) throw new Error('目标仓库不可用')
    await workspace.executeTaskOperations({
      operations: [{ type: 'Modification', data: { path: task.fullPath, modifications } }],
      queueRepoIds: repository.webdavEnabled ? [task.repoId] : [],
      fileVersions: [{ repoId: task.repoId, file: task.filePath, version: task.fileVersion }]
    })
  }

  static async reload(context: Context, task: CoreTask): Promise<CoreTask> {
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
    const tasks = (await workspace.query({ includeDone: true, includeComposeTasks: true })).tasks
    const current = tasks.find(item => item.repoId === task.repoId && item.filePath === task.filePath &&
      (task.taskId ? item.taskId === task.taskId : item.id === task.id))
    if (!current) throw new Error('任务已删除或改名，请返回列表重新打开')
    return current
  }

}

// 当前窗口只保留一个展开编辑会话，刷新推迟到会话结束，避免通知销毁输入控件。
export class TaskInlineSession {
  private static owner: string = ''
  private static finish: ((collapse: boolean) => Promise<boolean>) | undefined = undefined

  static async begin(key: string, finish: (collapse: boolean) => Promise<boolean>): Promise<boolean> {
    if (TaskInlineSession.owner && TaskInlineSession.owner !== key && !await TaskInlineSession.end(true)) return false
    TaskInlineSession.owner = key
    TaskInlineSession.finish = finish
    AppStorage.setOrCreate('taskInlineActive', key)
    return true
  }

  static async end(collapse: boolean): Promise<boolean> {
    return TaskInlineSession.finish ? await TaskInlineSession.finish(collapse) : true
  }

  static release(key: string) {
    if (TaskInlineSession.owner !== key) return
    TaskInlineSession.owner = ''
    TaskInlineSession.finish = undefined
    AppStorage.setOrCreate('taskInlineTyping', false)
    AppStorage.setOrCreate('taskInlineActive', '')
  }

  static active(): boolean { return TaskInlineSession.owner.length > 0 }
}
