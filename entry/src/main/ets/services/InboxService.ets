import { TaskStateCategory } from '../ui/TaskStatePresentation'
import { Context } from '@kit.AbilityKit'
import { AppConfig, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { MoveToTargetService } from './MoveToTargetService'
import { configuredFileTarget, FileTargetService, FileTargetQueryResult } from './FileTargetService'
import { CoreRefileTarget, CoreTask, CoreTaskPath, CoreTaskOperation, CoreTaskModification, CoreTaskFileVersion, CoreTaskQuery, CoreTaskMergeRequest, CoreTaskMergePlan, NativeCoreService, taskResult, fileResult } from './NativeCoreService'

import { PageQueryService } from './PageQueryService'

export interface InboxSnapshot { inbox: FileTargetQueryResult | undefined; recent: CoreTask[] }

export type InboxAction = 'move' | 'memo' | 'delete' | 'someday' | 'schedule' | 'deadline'

class InboxMergeChangedError extends Error {
  readonly code: string = 'invalidState'
  constructor(message: string) { super(message) }
}

// 只编排配置与 Core 请求，不解析 Org 或在宿主实现任务移动。
export class InboxService {
  static async merge(context: Context, records: CoreTask[]): Promise<CoreTaskPath> {
    if (records.length < 2) throw new Error('请至少选择两条记录')
    const first = records[0]
    if (records.some(item => item.repoId !== first.repoId || item.filePath !== first.filePath || item.fileVersion !== first.fileVersion)) {
      throw new InboxMergeChangedError('只能合并同一文件的同一版本，请刷新后重新选择')
    }
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const selected = configuredFileTarget(config, 'inbox')
    const settings = config.repos.find(item => item.id === selected.repoId)
    const repo = (await workspace.repos()).find(item => item.rootDirectory === settings?.rootDirectory)
    if (!settings || !repo || selected.path !== first.filePath) throw new InboxMergeChangedError('收件箱配置已变更，请刷新后重新选择')
    await repo.load()
    if (repo.id !== first.repoId) throw new InboxMergeChangedError('收件箱身份已变化，请刷新后重新选择')
    const request: CoreTaskMergeRequest = { paths: records.map(item => item.fullPath), fileVersion: first.fileVersion }
    const plan: CoreTaskMergePlan = await workspace.taskMergeOperations(request)
    plan.operationGroup.queueRepoIds = settings.webdavEnabled ? [repo.id] : []
    await workspace.executeTaskOperations(plan.operationGroup)
    return plan.mainPath
  }

  static async load(config: AppConfig): Promise<InboxSnapshot> {
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const prepared = FileTargetService.prepare(config, await workspace.repos(), 'inbox')
    const recent: CoreTaskQuery = { expression: 'cr.ge.-2d cr.le.today .o.created', includeComposeTasks: true,
      excludedFiles: prepared ? [prepared.reference] : [] }
    const results = await PageQueryService.query(config, prepared
      ? [prepared.task, prepared.file, { type: 'task', query: recent }] : [{ type: 'task', query: recent }])
    return { inbox: prepared ? FileTargetService.result(results[0], results[1]) : undefined,
      recent: taskResult(results[prepared ? 2 : 0]).tasks }
  }

  static async perform(context: Context, task: CoreTask, action: InboxAction,
    target?: CoreRefileTarget): Promise<void> {
    if (action === 'move') {
      if (!target) throw new Error('请选择任务目标')
      await MoveToTargetService.move(context, task, target)
      return
    }
    await InboxService.performMany(context, [task], action, target)
  }

  // 一次提交整组选中快照；任一版本或操作失效均由 Core 拒绝整组。
  static async performMany(context: Context, tasks: CoreTask[], action: InboxAction,
    target?: CoreRefileTarget, date?: string): Promise<void> {
    if (tasks.length === 0) return
    if (action === 'move' && !target) throw new Error('请选择任务目标')
    if ((action === 'schedule' || action === 'deadline') && date === undefined) throw new Error('请选择日期')
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const repos = await workspace.repos()
    const queueRepoIds: string[] = []
    for (const repo of repos) {
      await repo.load()
      const settings = config.repos.find((item: RepoConfig) => item.rootDirectory === repo.rootDirectory)
      if (settings?.webdavEnabled) queueRepoIds.push(repo.id)
    }
    let parent: CoreTaskPath | undefined = action === 'move' ? target!.fullPath : undefined
    const operations: CoreTaskOperation[] = []
    let modifications: CoreTaskModification[] = []
    if (action === 'schedule' || action === 'deadline') {
      modifications = [{ field: action === 'deadline' ? 'DEADLINE_DATE' : 'SCHEDULE_DATE', value: date || null }]
    } else if (action === 'someday') {
      const selected = configuredFileTarget(config, 'someday')
      const settings = config.repos.find((item: RepoConfig) => item.id === selected.repoId)
      const repo = repos.find(item => item.rootDirectory === settings?.rootDirectory)
      if (!repo || !selected.path) throw new Error('请在设置中选择“某天”文件，作为将来，也许的目标')
      const files = fileResult((await workspace.query([{ type: 'file', query: { includeFiles: [{ repoId: repo.id, path: selected.path }] } }]))[0])
      const metadata = files.find(file => file.path === selected.path && !file.isIgnore)
      if (!metadata) throw new Error('将来，也许文件已失效，请在设置中重新选择')
      const first = (await workspace.refileTargets({ files: [{ repoId: repo.id, path: selected.path }] }))[0]
      if (!first) throw new Error('请在将来，也许文件中添加 REFILE 标题')
      target = first
      parent = first.fullPath
      const state = metadata.taskStateOf(TaskStateCategory.Todo)
      if (!state) throw new Error('目标文件没有可用的待办状态，请检查状态分类与 TODO 流程')
      modifications = [
        { field: 'TODO', value: state.name }, { field: 'SCHEDULE', value: null },
        { field: 'DEADLINE', value: null }
      ]
    } else if (action === 'memo') {
      const selected = configuredFileTarget(config, 'memo')
      const settings = config.repos.find((item: RepoConfig) => item.id === selected.repoId)
      const repo = repos.find(item => item.rootDirectory === settings?.rootDirectory)
      if (!repo || !selected.path) throw new Error('备忘文件未选择或已失效，请在设置中重新选择')
      const files = fileResult((await workspace.query([{ type: 'file', query: { includeFiles: [{ repoId: repo.id, path: selected.path }] } }]))[0])
      if (!files.some(file => file.path === selected.path && !file.isIgnore)) {
        throw new Error('备忘文件未选择或已失效，请在设置中重新选择')
      }
      parent = (await repo.file(selected.path)).fullPath
      modifications = [
        { field: 'TODO', value: null }, { field: 'PRIORITY', value: null },
        { field: 'SCHEDULE', value: null }, { field: 'DEADLINE', value: null }
      ]
    }
    for (const task of tasks) {
      if (modifications.length > 0) operations.push({ type: 'Modification', data: { path: task.fullPath, modifications } })
      if (action === 'schedule' || action === 'deadline') continue
      operations.push(parent ? { type: 'Movement', data: { path: task.fullPath, position: { parent } } } :
      { type: 'Deletion', data: { path: task.fullPath } })
    }
    const fileVersions: CoreTaskFileVersion[] = tasks.map((task: CoreTask): CoreTaskFileVersion =>
      ({ repoId: task.repoId, file: task.filePath, version: task.fileVersion }))
    if (target && (action === 'someday' || action === 'move')) fileVersions.push({ repoId: target.repoId, file: target.path, version: target.fileVersion })
    await workspace.executeTaskOperations({ operations, queueRepoIds, fileVersions })
  }
}
