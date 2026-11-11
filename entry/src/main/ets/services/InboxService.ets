import { Context } from '@kit.AbilityKit'
import { RepoConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { configuredFileTarget } from './FileTargetService'
import { CoreRefileTarget, CoreTask, CoreTaskPath, CoreTaskOperation, CoreTaskFileVersion, CoreTaskQuery, CoreOrgFileRef, CoreTaskMergeRequest, CoreTaskMergePlan, NativeCoreService } from './NativeCoreService'

export type InboxAction = 'move' | 'memo' | 'delete' | 'someday'
export interface InboxTargets { targets: CoreRefileTarget[]; somedayTarget: CoreRefileTarget | undefined; somedayHint: string }

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
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
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

  static async targets(context: Context): Promise<InboxTargets> {
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
    const selected = configuredFileTarget(config, 'someday')
    const settings = config.repos.find((item: RepoConfig) => item.id === selected.repoId)
    const repos = await workspace.repos()
    const someday = repos.find(repo => repo.rootDirectory === settings?.rootDirectory)
    const excludedFiles: CoreOrgFileRef[] = []
    for (const file of [configuredFileTarget(config, 'inbox'), configuredFileTarget(config, 'someday')]) {
      const configured = config.repos.find((item: RepoConfig) => item.id === file.repoId)
      const repo = repos.find(item => item.rootDirectory === configured?.rootDirectory)
      if (repo && file.path) { await repo.load(); excludedFiles.push({ repoId: repo.id, path: file.path }) }
    }
    // 在 Core 读取 CATEGORY 之前排除特殊文件，宿主不再从返回结果移除目标。
    const normal = await workspace.refileTargets({ excludedFiles })
    let first: CoreRefileTarget | undefined = undefined
    let hint = '请在设置中选择“某天”文件，作为将来，也许的目标'
    if (someday && selected.path) {
      const files = await someday.fileMetadata()
      if (!files.some(file => file.path === selected.path && !file.isIgnore)) {
        first = undefined
        hint = '将来，也许文件已失效，请在设置中重新选择'
      } else {
        first = (await workspace.refileTargets({ files: [{ repoId: someday.id, path: selected.path }] }))[0]
        hint = first ? '' : '请在将来，也许文件中添加 REFILE 标题'
      }
    }
    return { targets: normal, somedayTarget: first, somedayHint: hint }
  }

  static async recent(context: Context): Promise<CoreTask[]> {
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
    const selected = configuredFileTarget(config, 'inbox')
    const settings = config.repos.find((item: RepoConfig) => item.id === selected.repoId)
    const repos = await workspace.repos()
    const inbox = repos.find(repo => repo.rootDirectory === settings?.rootDirectory)
    if (inbox) await inbox.load()
    const query: CoreTaskQuery = { expression: 'cr.ge.-2d cr.le.today .o.created', includeDone: true, includeComposeTasks: true,
      excludedFiles: inbox && selected.path ? [{ repoId: inbox.id, path: selected.path }] : [] }
    return (await workspace.query([query]))[0].tasks
  }

  static async perform(context: Context, task: CoreTask, action: InboxAction,
    target?: CoreRefileTarget): Promise<void> {
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
    const repos = await workspace.repos()
    const queueRepoIds: string[] = []
    for (const repo of repos) {
      await repo.load()
      const settings = config.repos.find((item: RepoConfig) => item.rootDirectory === repo.rootDirectory)
      if (settings?.webdavEnabled) queueRepoIds.push(repo.id)
    }
    let parent: CoreTaskPath | undefined = undefined
    const operations: CoreTaskOperation[] = []
    if (action === 'move') {
      if (!target) throw new Error('请选择任务目标')
      parent = target.fullPath
    } else if (action === 'someday') {
      const selected = configuredFileTarget(config, 'someday')
      const settings = config.repos.find((item: RepoConfig) => item.id === selected.repoId)
      const repo = repos.find(item => item.rootDirectory === settings?.rootDirectory)
      if (!repo || !selected.path) throw new Error('请在设置中选择“某天”文件，作为将来，也许的目标')
      const files = await repo.fileMetadata()
      if (!files.some(file => file.path === selected.path && !file.isIgnore)) {
        throw new Error('将来，也许文件已失效，请在设置中重新选择')
      }
      const first = (await workspace.refileTargets({ files: [{ repoId: repo.id, path: selected.path }] }))[0]
      if (!first) throw new Error('请在将来，也许文件中添加 REFILE 标题')
      target = first
      parent = first.fullPath
      operations.push({ type: 'Modification', data: { path: task.fullPath, modifications: [
        { field: 'TODO', value: 'TODO' }, { field: 'SCHEDULE', value: null },
        { field: 'DEADLINE', value: null }
      ] } })
    } else if (action === 'memo') {
      const selected = configuredFileTarget(config, 'memo')
      const settings = config.repos.find((item: RepoConfig) => item.id === selected.repoId)
      const repo = repos.find(item => item.rootDirectory === settings?.rootDirectory)
      if (!repo || !selected.path) throw new Error('备忘文件未选择或已失效，请在设置中重新选择')
      const files = await repo.fileMetadata()
      if (!files.some(file => file.path === selected.path && !file.isIgnore)) {
        throw new Error('备忘文件未选择或已失效，请在设置中重新选择')
      }
      parent = (await repo.file(selected.path)).fullPath
      operations.push({ type: 'Modification', data: { path: task.fullPath, modifications: [
        { field: 'TODO', value: null }, { field: 'PRIORITY', value: null },
        { field: 'SCHEDULE', value: null }, { field: 'DEADLINE', value: null }
      ] } })
    }
    operations.push(parent ? { type: 'Movement', data: { path: task.fullPath, position: { parent } } } :
      { type: 'Deletion', data: { path: task.fullPath } })
    const fileVersions: CoreTaskFileVersion[] = [{ repoId: task.repoId, file: task.filePath, version: task.fileVersion }]
    if (target && (action === 'move' || action === 'someday')) fileVersions.push({ repoId: target.repoId, file: target.path, version: target.fileVersion })
    await workspace.executeTaskOperations({ operations, queueRepoIds, fileVersions })
  }
}
