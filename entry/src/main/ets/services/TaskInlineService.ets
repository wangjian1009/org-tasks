import { Context } from '@kit.AbilityKit'
import { AppConfigService } from './AppConfigService'
import { CoreTask, CoreTaskModification, NativeCoreService, taskResult } from './NativeCoreService'
import { PageQueryService } from './PageQueryService'

// 只组装字段操作和快照版本；保真修改、校验与通知由 Core 完成。
export class TaskInlineService {
  private static changeRevision: number = -1
  private static changeSnapshot: Promise<CoreTask[]> | undefined = undefined

  static async modify(context: Context, task: CoreTask, modifications: CoreTaskModification[]): Promise<void> {
    if (modifications.length === 0) return
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
    const repo = (await workspace.repos()).find(item => item.id === task.repoId)
    const repository = config.repos.find(item => item.rootDirectory === repo?.rootDirectory)
    if (!repository) throw new Error('目标仓库不可用')
    // 字段值应用于最新快照；清单操作含快照条目 ID，继续校验原版本。
    const current = modifications.some(change => change.field === 'CHECKLIST') ? task :
      await TaskInlineService.reload(context, task)
    await workspace.executeTaskOperations({
      operations: [{ type: 'Modification', data: { path: current.fullPath, modifications } }],
      queueRepoIds: repository.webdavEnabled ? [task.repoId] : [],
      fileVersions: [{ repoId: current.repoId, file: current.filePath, version: current.fileVersion }]
    })
  }

  static async reload(context: Context, task: CoreTask): Promise<CoreTask> {
    const current = await TaskInlineService.find(context, task)
    if (!current) throw new Error('任务已删除或改名，请返回列表重新打开')
    return current
  }

  static async find(context: Context, task: CoreTask): Promise<CoreTask | undefined> {
    const config = await AppConfigService.load(context, false)
    const tasks = taskResult((await PageQueryService.query(config, [{ type: 'task', query: { includeDone: true, includeComposeTasks: true } }]))[0]).tasks
    return tasks.find(item => item.repoId === task.repoId && item.filePath === task.filePath &&
      ((!!task.taskId && item.taskId === task.taskId) || item.id === task.id))
  }

  static async findChanged(context: Context, task: CoreTask, revision: number): Promise<CoreTask | undefined> {
    // 同一数据版本的可见任务行共用一次批量查询；写入前的 reload 仍独立读取最新文件。
    if (TaskInlineService.changeRevision !== revision || !TaskInlineService.changeSnapshot) {
      TaskInlineService.changeRevision = revision
      TaskInlineService.changeSnapshot = TaskInlineService.changedTasks(context).catch((error: Error): never => {
        if (TaskInlineService.changeRevision === revision) TaskInlineService.changeSnapshot = undefined
        throw error
      })
    }
    const tasks = await TaskInlineService.changeSnapshot
    return tasks.find(item => item.repoId === task.repoId && item.filePath === task.filePath &&
      ((!!task.taskId && item.taskId === task.taskId) || item.id === task.id))
  }

  private static async changedTasks(context: Context): Promise<CoreTask[]> {
    const config = await AppConfigService.load(context, false)
    return taskResult((await PageQueryService.query(config, [{ type: 'task', query: {
      includeDone: true, includeComposeTasks: true
    } }]))[0]).tasks
  }

}

// 当前窗口只保留一个展开编辑会话；列表重排推迟到会话结束，卡片快照与通知继续刷新。
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
