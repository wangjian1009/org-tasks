import { Context } from '@kit.AbilityKit'
import { AppConfigService } from './AppConfigService'
import { CoreTask, CoreTaskModification, NativeCoreService, taskResult } from './NativeCoreService'
import { PageQueryService } from './PageQueryService'
import { CoreDataChangeService } from './CoreDataChangeService'

export class TaskInlineMissingError extends Error {
  constructor() { super('任务已删除或改名，请返回列表重新打开') }
}

// 只组装字段操作和快照版本；保真修改、校验与通知由 Core 完成。
export class TaskInlineService {
  private static changeRevision: number = -1
  private static changeSnapshot: Promise<CoreTask[]> | undefined = undefined
  private static documentRevision: number = -1
  private static documentSnapshots: Map<string, Promise<CoreTask[]>> = new Map()

  static async modify(context: Context, task: CoreTask, modifications: CoreTaskModification[], documentMode: boolean = false): Promise<void> {
    if (modifications.length === 0) return
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    // 完整文件读取不经过 PageQueryService，提交前确保数据订阅已经注册。
    if (documentMode) await CoreDataChangeService.connect(workspace)
    const repo = (await workspace.repos()).find(item => item.id === task.repoId)
    const repository = config.repos.find(item => item.rootDirectory === repo?.rootDirectory)
    if (!repository) throw new Error('目标仓库不可用')
    // 字段值应用于最新快照；清单与链接操作引用快照位置，继续校验原版本。
    const current = modifications.some(change => change.field === 'CHECKLIST' || change.field === 'LINK' || change.field === 'CONTENT_BLOCK') ? task :
      await TaskInlineService.reload(context, task, documentMode)
    await workspace.executeTaskOperations({
      operations: [{ type: 'Modification', data: { path: current.fullPath, modifications } }],
      queueRepoIds: repository.webdavEnabled ? [task.repoId] : [],
      fileVersions: [{ repoId: current.repoId, file: current.filePath, version: current.fileVersion }]
    })
    // 同一数据事件的共享查询可能早于本次提交，不能再用于后续编辑。
    TaskInlineService.changeSnapshot = undefined
    TaskInlineService.documentSnapshots = new Map()
  }

  static async reload(context: Context, task: CoreTask, documentMode: boolean = false): Promise<CoreTask> {
    const current = await TaskInlineService.find(context, task, documentMode)
    if (!current) throw new TaskInlineMissingError()
    return current
  }

  static async find(context: Context, task: CoreTask, documentMode: boolean = false): Promise<CoreTask | undefined> {
    if (documentMode) return TaskInlineService.match(await TaskInlineService.documentTasks(context, task), task)
    const config = await AppConfigService.load(context, false)
    const tasks = taskResult((await PageQueryService.query(config, [{ type: 'task', query: { includeComposeTasks: true } }]))[0]).tasks
    return TaskInlineService.match(tasks, task)
  }

  static async findChanged(context: Context, task: CoreTask, revision: number, documentMode: boolean = false): Promise<CoreTask | undefined> {
    if (documentMode) {
      if (TaskInlineService.documentRevision !== revision) {
        TaskInlineService.documentRevision = revision
        TaskInlineService.documentSnapshots = new Map()
      }
      // 文档节点不受任务扫描规则影响；同一事件的所有任务行共用目标文件快照。
      const snapshots = TaskInlineService.documentSnapshots
      const key = JSON.stringify([task.repoId, task.filePath])
      let snapshot = snapshots.get(key)
      if (!snapshot) {
        snapshot = TaskInlineService.documentTasks(context, task).catch((error: Error): never => {
          snapshots.delete(key)
          throw error
        })
        snapshots.set(key, snapshot)
      }
      return TaskInlineService.match(await snapshot, task)
    }
    // 同一数据版本的可见任务行共用一次批量查询；写入前的 reload 仍独立读取最新文件。
    if (TaskInlineService.changeRevision !== revision || !TaskInlineService.changeSnapshot) {
      TaskInlineService.changeRevision = revision
      TaskInlineService.changeSnapshot = TaskInlineService.changedTasks(context).catch((error: Error): never => {
        if (TaskInlineService.changeRevision === revision) TaskInlineService.changeSnapshot = undefined
        throw error
      })
    }
    const tasks = await TaskInlineService.changeSnapshot
    return TaskInlineService.match(tasks, task)
  }

  private static match(tasks: CoreTask[], task: CoreTask): CoreTask | undefined {
    return tasks.find(item => item.repoId === task.repoId && item.filePath === task.filePath &&
      ((!!task.taskId && item.taskId === task.taskId) || item.id === task.id))
  }

  private static async documentTasks(context: Context, task: CoreTask): Promise<CoreTask[]> {
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const file = await workspace.fileAt({ repoId: task.repoId, file: task.filePath, titles: [], occurrence: 1 })
    return file.nodes()
  }

  private static async changedTasks(context: Context): Promise<CoreTask[]> {
    const config = await AppConfigService.load(context, false)
    return taskResult((await PageQueryService.query(config, [{ type: 'task', query: {
      includeComposeTasks: true
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
