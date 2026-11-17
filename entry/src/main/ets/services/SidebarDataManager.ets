import { Context } from '@kit.AbilityKit'
import { AppConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { CoreDataChangeService } from './CoreDataChangeService'
import { FileTargetKind, FileTargetService, fileTargetRepository } from './FileTargetService'
import { PageQueryService } from './PageQueryService'
import { PageDataCache } from './PageDataCache'
import { CachedDataSet, cacheDataSet, restoreDataSet } from './PageDataSnapshot'
import { samePageMetadata } from './PageDataEquality'
import { overviewTaskQuery, todayAttentionQuery } from './TaskViewQueries'
import { CoreBridgeError, CoreOrgFileMetadata, CoreSettingsObject, CoreQuery, CoreQueryResult, NativeCoreService, taskResult, fileResult, coreErrorMessage } from './NativeCoreService'
import { SYSTEM_REPOSITORY_ID, TRASH_FILE } from '../models/SystemRepository'

export interface SidebarSnapshot {
  version: number
  inboxCount: number
  todayCount: number
  todayAttentionCount: number
  plannedCount: number
  waitingCount: number
  anytimeCount: number
  somedayCount: number
  memoCount: number
  logbookCount: number
  projects: CoreOrgFileMetadata[]
  message: string
}
interface SidebarCacheRepo { id: string; rootDirectory: string; excludedDirectories: string[] }
interface SidebarCacheScope { repositories: SidebarCacheRepo[]; todoDefaults: string; coreSettings: CoreSettingsObject; queries: CoreQuery[] }
interface SidebarQueryPlan { queries: CoreQuery[]; positions: number[] }

export function emptySidebarSnapshot(): SidebarSnapshot {
  return { version: 0, inboxCount: -1, todayCount: -1, todayAttentionCount: 0, plannedCount: -1,
    waitingCount: -1, anytimeCount: -1, somedayCount: -1, memoCount: -1, logbookCount: -1, projects: [], message: '' }
}

// 只读侧边栏数据入口：缓存不限定订阅范围，任何仓库变化均可引入新项目。
export class SidebarDataManager {
  private readonly context: Context
  private readonly listeners: Set<(snapshot: SidebarSnapshot) => void> = new Set()
  private snapshot: SidebarSnapshot = emptySidebarSnapshot()
  private stopEvents: (() => void) | undefined = undefined
  private reading: Promise<void> | undefined = undefined
  private timer: number = -1
  private dayTimer: number = -1
  private day: string = new Date().toDateString()
  private revision: number = 0
  private version: number = 0
  private pending: boolean = true
  private closed: boolean = false
  private cacheScope: string = ''
  private cache: PageDataCache | undefined = undefined
  private invalidate = (): void => {
    if (this.closed) return
    this.revision++
    this.pending = true
    this.scheduleRead()
  }

  private scheduleRead(): void {
    if (this.closed || !this.pending || this.timer >= 0 || this.reading) return
    this.timer = setTimeout((): void => { this.timer = -1; this.start() }, 50)
  }

  constructor(context: Context) { this.context = context }

  subscribe(listener: (snapshot: SidebarSnapshot) => void): () => void {
    this.listeners.add(listener)
    listener(this.snapshot)
    return (): void => { this.listeners.delete(listener) }
  }

  start(): Promise<void> {
    if (this.closed) return Promise.resolve()
    if (!this.stopEvents) {
      this.stopEvents = CoreDataChangeService.watchEvents(this.invalidate)
      AppConfigService.watchChanges(this.invalidate)
      this.dayTimer = setInterval((): void => {
        const day = new Date().toDateString()
        if (day !== this.day) { this.day = day; this.invalidate() }
      }, 60000)
    }
    if (this.snapshot.message) this.pending = true
    if (!this.reading && this.pending) {
      this.reading = this.read().finally((): void => { this.reading = undefined; this.scheduleRead() })
    }
    return this.reading ?? Promise.resolve()
  }

  async targetConfigured(kind: FileTargetKind): Promise<boolean> {
    return fileTargetRepository(await AppConfigService.load(this.context, false), kind) !== undefined
  }

  private async plan(config: AppConfig): Promise<SidebarQueryPlan> {
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const repos = await workspace.repos()
    const queries: CoreQuery[] = [
      { type: 'task', query: overviewTaskQuery('today') }, { type: 'task', query: todayAttentionQuery() },
      { type: 'task', query: overviewTaskQuery('planned') }, { type: 'task', query: overviewTaskQuery('anytime') },
      { type: 'task', query: overviewTaskQuery('logbook') }, { type: 'file', query: { isProject: true } },
      { type: 'task', query: overviewTaskQuery('waiting') }
    ]
    const system = config.repos.find(repo => repo.id === SYSTEM_REPOSITORY_ID)
    const trashRepo = repos.find(repo => repo.rootDirectory === system?.rootDirectory)
    if (trashRepo) for (const request of queries) {
      if (request.type === 'task' || request.type === 'file') request.query.excludeFiles = [{ repoId: trashRepo.id, path: TRASH_FILE }]
    }
    const positions: number[] = []
    const kinds: FileTargetKind[] = ['inbox', 'someday', 'memo']
    for (const kind of kinds) {
      const target = FileTargetService.prepare(config, repos, kind)
      positions.push(target ? queries.length : -1)
      if (target) { queries.push(target.task); queries.push(target.file) }
    }
    return { queries, positions }
  }

  private async read(): Promise<void> {
    while (this.pending && !this.closed) {
      this.pending = false
      const revision = this.revision
      try {
        const config = await AppConfigService.load(this.context, false)
        const plan = await this.plan(config)
        if (this.closed || revision !== this.revision) continue
        const identity: SidebarCacheScope = { repositories: config.repos.map((repo): SidebarCacheRepo =>
          ({ id: repo.id, rootDirectory: repo.rootDirectory, excludedDirectories: repo.excludedDirectories })),
          todoDefaults: config.todoDefaults, coreSettings: config.coreSettings, queries: plan.queries }
        const scope = JSON.stringify(identity)
        if (scope !== this.cacheScope) {
          this.cacheScope = scope
          this.cache = new PageDataCache(this.context, 'sidebar', scope)
          this.version = 0
          this.publish(emptySidebarSnapshot())
          try {
            const cached = await this.cache.read()
            if (!this.closed && revision === this.revision && cached?.length === plan.queries.length &&
              cached.every((item, index) => item.name === `${index}` && item.type === plan.queries[index].type)) {
              this.apply(cached.map(item => restoreDataSet(item)), plan, 0)
            }
          } catch (_) { /* 缓存损坏不阻止读取当前完整快照。 */ }
        }
        if (this.closed || revision !== this.revision) continue
        // PageQueryService 在查询前注册整个 Workspace 的变化，缓存中没有的文件同样能触发后续刷新。
        const results = await PageQueryService.query(config, plan.queries)
        if (this.closed || revision !== this.revision) continue
        this.apply(results, plan, ++this.version)
        const cached: CachedDataSet[] = results.map((result, index) => cacheDataSet(`${index}`, result))
        await this.cache?.write(cached, (): boolean => !this.closed && revision === this.revision)
      } catch (error) {
        if (!this.closed && revision === this.revision) {
          const current = this.snapshot
          const next: SidebarSnapshot = { version: current.version, inboxCount: current.inboxCount, todayCount: current.todayCount,
            todayAttentionCount: current.todayAttentionCount, plannedCount: current.plannedCount, waitingCount: current.waitingCount, anytimeCount: current.anytimeCount,
            somedayCount: current.somedayCount, memoCount: current.memoCount, logbookCount: current.logbookCount, projects: current.projects,
            message: `读取导航失败：${coreErrorMessage(error as CoreBridgeError)}` }
          this.publish(next)
        }
      }
    }
  }

  private apply(results: CoreQueryResult[], plan: SidebarQueryPlan, version: number): void {
    const counts = plan.positions.map(position => position < 0 ? -1 :
      FileTargetService.result(results[position], results[position + 1])?.tasks.length ?? -1)
    this.publish({ version, todayCount: taskResult(results[0]).tasks.length, todayAttentionCount: taskResult(results[1]).tasks.length,
      plannedCount: taskResult(results[2]).tasks.length, anytimeCount: taskResult(results[3]).tasks.length,
      logbookCount: taskResult(results[4]).tasks.length, projects: fileResult(results[5]), waitingCount: taskResult(results[6]).tasks.length,
      inboxCount: counts[0], somedayCount: counts[1], memoCount: counts[2], message: '' })
  }

  private publish(next: SidebarSnapshot): void {
    const previous = this.snapshot
    const unchanged = previous.version === next.version && previous.message === next.message &&
      previous.inboxCount === next.inboxCount && previous.todayCount === next.todayCount &&
      previous.todayAttentionCount === next.todayAttentionCount && previous.plannedCount === next.plannedCount &&
      previous.waitingCount === next.waitingCount && previous.anytimeCount === next.anytimeCount && previous.somedayCount === next.somedayCount &&
      previous.memoCount === next.memoCount && previous.logbookCount === next.logbookCount &&
      previous.projects.length === next.projects.length && previous.projects.every((file, index) => samePageMetadata(file, next.projects[index]))
    this.snapshot = next
    if (!unchanged) for (const listener of this.listeners) listener(next)
  }

  close(): void {
    this.closed = true
    this.stopEvents?.(); this.stopEvents = undefined
    AppConfigService.stopWatchingChanges(this.invalidate)
    clearTimeout(this.timer); clearInterval(this.dayTimer)
    this.listeners.clear()
  }
}
