import { Context } from '@kit.AbilityKit'
import { AppDataManager } from './AppDataManager'
import { FileTargetKind } from './FileTargetService'
import { CoreOrgFileMetadata } from './NativeCoreService'
import { samePageMetadata } from './PageDataEquality'

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
  trashCount: number
  projects: CoreOrgFileMetadata[]
  message: string
}
export function emptySidebarSnapshot(): SidebarSnapshot {
  return { version: 0, inboxCount: -1, todayCount: -1, todayAttentionCount: 0, plannedCount: -1,
    waitingCount: -1, anytimeCount: -1, somedayCount: -1, memoCount: -1, logbookCount: -1, trashCount: -1, projects: [], message: '' }
}

const SIDEBAR_DATA_SETS: string[] = ['todayTasks', 'todayAttention', 'planned', 'anytime', 'waiting', 'logbook',
  'projects', 'trash', 'inboxTasks', 'inboxFile', 'somedayTasks', 'somedayFile', 'memoTasks', 'memoFile']

// 侧边栏只投影全局 DataSet；关闭抽屉不释放共享查询或缓存。
export class SidebarDataManager {
  private readonly app: AppDataManager
  private readonly listeners: Set<(snapshot: SidebarSnapshot) => void> = new Set()
  private snapshot: SidebarSnapshot = emptySidebarSnapshot()
  private readonly stops: (() => void)[] = []
  private closed: boolean = false
  private timer: number = -1

  constructor(context: Context) {
    this.app = AppDataManager.shared(context)
    for (const name of SIDEBAR_DATA_SETS) this.stops.push(this.app.dataSet(name).subscribe((): void => {
      if (this.closed || this.timer >= 0) return
      this.timer = setTimeout((): void => { this.timer = -1; this.publish() }, 0)
    }))
    this.publish()
  }
  subscribe(listener: (snapshot: SidebarSnapshot) => void): () => void {
    this.listeners.add(listener); listener(this.snapshot)
    return (): void => { this.listeners.delete(listener) }
  }
  async start(): Promise<void> {
    if (this.closed) return
    try { await this.app.start(); await this.app.retryFailed(); this.publish() }
    catch (error) { this.publish((error as Error).message) }
  }
  async targetConfigured(kind: FileTargetKind): Promise<boolean> { return await this.app.targetConfigured(kind) }
  private count(name: string): number {
    const data = this.app.dataSet(name).data
    return data?.type === 'task' ? data.result.tasks.length : -1
  }
  private publish(message: string = ''): void {
    if (this.closed) return
    const projects = this.app.dataSet('projects').data
    const next: SidebarSnapshot = {
      version: Math.max(...SIDEBAR_DATA_SETS.map(name => this.app.dataSet(name).version)),
      todayCount: this.count('todayTasks'), todayAttentionCount: Math.max(0, this.count('todayAttention')),
      plannedCount: this.count('planned'), anytimeCount: this.count('anytime'), waitingCount: this.count('waiting'),
      logbookCount: this.count('logbook'), trashCount: Math.max(0, this.count('trash')),
      inboxCount: this.app.targetCount('inbox'), somedayCount: this.app.targetCount('someday'), memoCount: this.app.targetCount('memo'),
      projects: projects?.type === 'file' ? projects.result : [],
      message: message || SIDEBAR_DATA_SETS.map(name => this.app.dataSet(name).error).find(error => !!error) || ''
    }
    const previous = this.snapshot
    const unchanged = previous.version === next.version && previous.message === next.message &&
      previous.inboxCount === next.inboxCount && previous.todayCount === next.todayCount &&
      previous.todayAttentionCount === next.todayAttentionCount && previous.plannedCount === next.plannedCount &&
      previous.waitingCount === next.waitingCount && previous.anytimeCount === next.anytimeCount && previous.somedayCount === next.somedayCount &&
      previous.memoCount === next.memoCount && previous.logbookCount === next.logbookCount && previous.trashCount === next.trashCount &&
      previous.projects.length === next.projects.length && previous.projects.every((file, index) => samePageMetadata(file, next.projects[index]))
    this.snapshot = next
    if (!unchanged) for (const listener of this.listeners) listener(next)
  }
  close(): void {
    this.closed = true; clearTimeout(this.timer)
    for (const stop of this.stops) stop()
    this.listeners.clear()
  }
}
