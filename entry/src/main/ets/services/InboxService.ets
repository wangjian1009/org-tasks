import { localizedText } from '../ui/LocalizedText'
import { SYSTEM_REPOSITORY_ID, TRASH_FILE } from '../models/SystemRepository'
import { Context } from '@kit.AbilityKit'
import { AppConfig, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { TrashService } from './TrashService'
import { MoveToTargetService } from './MoveToTargetService'
import { configuredFileTarget, FileTargetService, FileTargetQueryResult } from './FileTargetService'
import { CoreRefileTarget, CoreTaskPlanningEdit, CoreTask, CoreTaskPath, CoreTaskOperation, CoreTaskModification, CoreTaskFileVersion, CoreTaskQuery, CoreTaskMergeRequest, CoreTaskMergePlan, CoreTaskOperationGroup, NativeCoreService, taskResult, fileResult } from './NativeCoreService'

import { PageQueryService } from './PageQueryService'
import { mergeTaskOperationGroups } from './TaskOperationGroups'

export interface InboxSnapshot { inbox: FileTargetQueryResult | undefined; recent: CoreTask[] }

export type InboxAction = 'move' | 'memo' | 'delete' | 'someday' | 'schedule' | 'deadline'

class InboxMergeChangedError extends Error {
  readonly code: string = 'invalidState'
  constructor(message: string) { super(message) }
}

// 只编排配置与 Core 请求，不解析 Org 或在宿主实现任务移动。
export class InboxService {
  static async mergePlan(context: Context, records: CoreTask[]): Promise<CoreTaskMergePlan> {
    if (records.length < 2) throw new Error(localizedText($r('app.string.text_please_select_at_least_two_records')))
    const first = records[0]
    if (records.some(item => item.repoId !== first.repoId || item.filePath !== first.filePath || item.fileVersion !== first.fileVersion)) {
      throw new InboxMergeChangedError(localizedText($r('app.string.text_only_the_same_version_of_the_same')))
    }
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const selected = configuredFileTarget(config, 'inbox')
    const settings = config.repos.find(item => item.id === selected.repoId)
    const repo = (await workspace.repos()).find(item => item.rootDirectory === settings?.rootDirectory)
    if (!settings || !repo || selected.path !== first.filePath) throw new InboxMergeChangedError(localizedText($r('app.string.text_inbox_configuration_changed_please_refresh_and_reselect')))
    await repo.load()
    if (repo.id !== first.repoId) throw new InboxMergeChangedError(localizedText($r('app.string.text_inbox_identity_changed_please_refresh_and_recheck')))
    const request: CoreTaskMergeRequest = { paths: records.map(item => item.fullPath), fileVersion: first.fileVersion }
    const plan: CoreTaskMergePlan = await workspace.taskMergeOperations(request)

    return plan
  }

  static async load(config: AppConfig): Promise<InboxSnapshot> {
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const repos = await workspace.repos()
    const system = config.repos.find(repo => repo.id === SYSTEM_REPOSITORY_ID)
    const trashRepo = repos.find(repo => repo.rootDirectory === system?.rootDirectory)
    const prepared = FileTargetService.prepare(config, repos, 'inbox')
    const recent: CoreTaskQuery = { expression: 'cr.ge.-2d cr.le.today .o.created',
      excludeFiles: (prepared ? [prepared.reference] : []).concat(trashRepo ? [{ repoId: trashRepo.id, path: TRASH_FILE }] : []) }
    const results = await PageQueryService.query(config, prepared
      ? [prepared.task, prepared.file, { type: 'task', query: recent }] : [{ type: 'task', query: recent }])
    return { inbox: prepared ? FileTargetService.result(results[0], results[1]) : undefined,
      recent: taskResult(results[prepared ? 2 : 0]).tasks }
  }

  static async perform(context: Context, task: CoreTask, action: InboxAction,
    target?: CoreRefileTarget): Promise<void> {
    if (action === 'move') {
      if (!target) throw new Error(localizedText($r('app.string.text_please_select_a_mission_target')))
      await MoveToTargetService.move(context, task, target)
      return
    }
    await InboxService.performMany(context, [task], action, target)
  }

  // 一次提交整组选中快照；任一版本或操作失效均由 Core 拒绝整组。
  static async performMany(context: Context, tasks: CoreTask[], action: InboxAction,
    target?: CoreRefileTarget, date?: CoreTaskPlanningEdit | null, operationId?: string): Promise<void> {
    const groups = await InboxService.operationGroups(context, tasks, action, target, date)
    const group = mergeTaskOperationGroups(groups)
    if (!group.operations.length) return
    if (operationId) group.operationId = operationId
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    await workspace.executeTaskOperations(group)
  }

  static async operationGroups(context: Context, tasks: CoreTask[], action: InboxAction,
    target?: CoreRefileTarget, date?: CoreTaskPlanningEdit | null): Promise<CoreTaskOperationGroup[]> {
    if (tasks.length === 0) return []
    if (action === 'move' && !target) throw new Error(localizedText($r('app.string.text_please_select_a_mission_target')))
    if ((action === 'schedule' || action === 'deadline') && date === undefined) throw new Error(localizedText($r('app.string.text_please_select_the_date')))
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    if (action === 'delete') return [await TrashService.group(config, workspace, tasks, 'trash')]
    const repos = await workspace.repos()
    let parent: CoreTaskPath | undefined = action === 'move' ? target!.fullPath : undefined
    let destinationVersion: CoreTaskFileVersion | undefined = undefined
    const groups: CoreTaskOperationGroup[] = []
    let modifications: CoreTaskModification[] = []
    if (action === 'schedule' || action === 'deadline') {
      modifications = [{ field: action === 'deadline' ? 'DEADLINE' : 'SCHEDULE', value: date ?? null }]
    } else if (action === 'someday') {
      const selected = configuredFileTarget(config, 'someday')
      const settings = config.repos.find((item: RepoConfig) => item.id === selected.repoId)
      const repo = repos.find(item => item.rootDirectory === settings?.rootDirectory)
      if (!repo || !selected.path) throw new Error(localizedText($r('app.string.text_select_the_day_file_in_the_settings')))
      const files = fileResult((await workspace.query([{ type: 'file', query: { includeFiles: [{ repoId: repo.id, path: selected.path }] } }]))[0])
      const metadata = files.find(file => file.path === selected.path && !file.isIgnore)
      if (!metadata) throw new Error(localizedText($r('app.string.text_in_the_future_perhaps_the_file_is')))
      // 复用 Core Trash 的来源记录与叶节点规则，直接归入配置文件头。
      return tasks.map((task: CoreTask): CoreTaskOperationGroup => ({
        operations: [{ type: 'Trash', data: { path: task.fullPath, target: { repoId: repo.id, path: selected.path } } }],
        fileVersions: [
          { repoId: task.repoId, file: task.filePath, version: task.fileVersion },
          { repoId: repo.id, file: selected.path, version: metadata.fileVersion }
        ]
      }))
    } else if (action === 'memo') {
      const selected = configuredFileTarget(config, 'memo')
      const settings = config.repos.find((item: RepoConfig) => item.id === selected.repoId)
      const repo = repos.find(item => item.rootDirectory === settings?.rootDirectory)
      if (!repo || !selected.path) throw new Error(localizedText($r('app.string.text_the_memo_file_is_not_selected_or')))
      const files = fileResult((await workspace.query([{ type: 'file', query: { includeFiles: [{ repoId: repo.id, path: selected.path }] } }]))[0])
      const metadata = files.find(file => file.path === selected.path && !file.isIgnore)
      if (!metadata) throw new Error(localizedText($r('app.string.text_the_memo_file_is_not_selected_or')))
      destinationVersion = { repoId: repo.id, file: selected.path, version: metadata.fileVersion }
      parent = (await repo.file(selected.path)).fullPath
      modifications = [
        { field: 'TODO', value: null }, { field: 'PRIORITY', value: null },
        { field: 'SCHEDULE', value: null }, { field: 'DEADLINE', value: null }
      ]
    }
    for (const task of tasks) {
      const operations: CoreTaskOperation[] = []
      if (modifications.length > 0) operations.push({ type: 'Modification', data: { path: task.fullPath, modifications } })
      if (action !== 'schedule' && action !== 'deadline') {
        if (!parent) throw new Error(localizedText($r('app.string.text_moving_target_is_not_available_re_select')))
        operations.push({ type: 'Movement', data: { path: task.fullPath, position: { parent } } })
      }
      const fileVersions: CoreTaskFileVersion[] = [{ repoId: task.repoId, file: task.filePath, version: task.fileVersion }]
      if (destinationVersion) fileVersions.push(destinationVersion)
      if (target && action === 'move') fileVersions.push({ repoId: target.repoId, file: target.path, version: target.fileVersion })
      groups.push({ operations, fileVersions })
    }
    return groups
  }
}
