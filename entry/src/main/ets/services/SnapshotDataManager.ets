import { Context } from '@kit.AbilityKit'
import { AppConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { CoreWorkspace, CoreDataChangeEvent, NativeCoreService } from './NativeCoreService'
import { RepositorySyncService, RepositorySyncState } from './RepositorySyncService'

export interface SnapshotState<T> { value?: T; message: string; revision: number }

// 完整文件与同步历史不能用任务查询替代；管理对象持有读取、失效合并和订阅生命周期。
export class SnapshotDataManager<T> {
  private readonly context: Context
  private readonly read: (config: AppConfig, workspace: CoreWorkspace) => Promise<T>
  private readonly accepts: (event: CoreDataChangeEvent) => boolean
  private readonly listeners: Set<(state: SnapshotState<T>) => void> = new Set()
  private state: SnapshotState<T> = { message: '', revision: 0 }
  private workspace: CoreWorkspace | undefined = undefined
  private subscription: number = 0
  private generation: number = 0
  private pending: boolean = true
  private closed: boolean = false
  private running: Promise<void> | undefined = undefined
  private timer: number = -1
  private started: boolean = false
  private syncRunning: boolean = false
  private syncChanged = (state: RepositorySyncState): void => {
    const finished = this.syncRunning && !state.running
    this.syncRunning = state.running
    if (finished) this.invalidate()
  }
  private configChanged = (): void => { this.invalidate() }
  constructor(context: Context, read: (config: AppConfig, workspace: CoreWorkspace) => Promise<T>,
    accepts: (event: CoreDataChangeEvent) => boolean = (): boolean => true) {
    this.context = context; this.read = read; this.accepts = accepts
  }
  subscribe(listener: (state: SnapshotState<T>) => void): () => void {
    this.listeners.add(listener)
    listener(this.state)
    return (): void => { this.listeners.delete(listener) }
  }
  start(): Promise<void> {
    if (this.closed) return Promise.resolve()
    if (!this.started) {
      this.started = true
      AppConfigService.watchChanges(this.configChanged)
      RepositorySyncService.watch(this.syncChanged)
    }
    if (!this.running && this.pending) {
      this.running = this.drain().finally((): void => { this.running = undefined; this.schedule() })
    }
    return this.running ?? Promise.resolve()
  }
  refresh(): Promise<void> { this.generation++; this.pending = true; return this.start() }
  private invalidate(): void { if (this.closed) return; this.generation++; this.pending = true; this.schedule() }
  private schedule(): void {
    if (this.closed || !this.pending || this.running || this.timer >= 0) return
    this.timer = setTimeout((): void => { this.timer = -1; this.start() }, 50)
  }
  private async drain(): Promise<void> {
    while (!this.closed && this.pending) {
      this.pending = false
      const generation = this.generation
      try {
        const config = await AppConfigService.load(this.context, false)
        const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
        if (this.closed || generation !== this.generation) continue
        if (workspace !== this.workspace || !this.subscription) {
          if (this.subscription) this.workspace?.stopWatchingDataChanges(this.subscription)
          this.subscription = 0; this.workspace = workspace
          const subscription = await workspace.watchDataChanges((event: CoreDataChangeEvent): void => {
            if (workspace === this.workspace && this.accepts(event)) this.invalidate()
          })
          if (this.closed || workspace !== this.workspace) { workspace.stopWatchingDataChanges(subscription); return }
          this.subscription = subscription
        }
        const value = await this.read(config, workspace)
        if (this.closed || generation !== this.generation) continue
        this.state = { value, message: '', revision: this.state.revision + 1 }
      } catch (error) {
        if (this.closed || generation !== this.generation) continue
        this.state = { value: this.state.value, message: (error as Error).message, revision: this.state.revision + 1 }
      }
      for (const listener of this.listeners) listener(this.state)
    }
  }
  close(): void {
    this.closed = true; this.generation++
    clearTimeout(this.timer)
    AppConfigService.stopWatchingChanges(this.configChanged)
    RepositorySyncService.stopWatching(this.syncChanged)
    if (this.subscription) this.workspace?.stopWatchingDataChanges(this.subscription)
    this.subscription = 0; this.listeners.clear()
  }
}
