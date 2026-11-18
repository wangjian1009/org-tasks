import { AppDataManager } from './AppDataManager'
import { Context } from '@kit.AbilityKit'
import { AppConfig } from '../models/OrgTask'
import { CoreRepo, CoreOrgFile, CoreSyncRecord, CoreSyncRecordDetail, CoreWorkspace, NativeCoreService } from './NativeCoreService'
import { NotebookService, NotebookGroup } from './NotebookService'
import { SnapshotState, SnapshotDataManager } from './SnapshotDataManager'
import { repositoryLabel } from '../ui/Theme'

export interface NotebookSnapshot { config: AppConfig; groups: NotebookGroup[] }
export class NotebookDataManager {
  private readonly app: AppDataManager
  private readonly listeners: Set<(state: SnapshotState<NotebookSnapshot>) => void> = new Set()
  private state: SnapshotState<NotebookSnapshot> = { message: '', revision: 0 }
  private readonly stopData: () => void
  private closed: boolean = false
  constructor(context: Context) {
    this.app = AppDataManager.shared(context)
    this.stopData = this.app.dataSet('notebookFiles').subscribe((): void => { this.publish() })
    this.publish()
  }
  subscribe(listener: (state: SnapshotState<NotebookSnapshot>) => void): () => void {
    this.listeners.add(listener); listener(this.state)
    return (): void => { this.listeners.delete(listener) }
  }
  private publish(): void {
    if (this.closed) return
    const dataSet = this.app.dataSet('notebookFiles'), data = dataSet.data, config = this.app.configuration
    if (!config || data?.type !== 'file') return
    const groups: NotebookGroup[] = this.app.manager.repositoryInfo.map((repo: CoreRepo): NotebookGroup => {
      const repository = config.repos.find(item => item.rootDirectory === repo.rootDirectory)
      return { repoId: repo.id, configId: repository?.id || '', name: repositoryLabel(repository),
        rootDirectory: repo.rootDirectory, files: data.result.filter(file => file.repoId === repo.id), message: dataSet.error }
    })
    this.state = { value: { config, groups }, message: dataSet.error, revision: this.state.revision + 1 }
    for (const listener of this.listeners) listener(this.state)
  }
  async start(): Promise<void> {
    try { await this.app.start() }
    catch (error) {
      if (this.closed) return
      this.state = { value: this.state.value, message: (error as Error).message, revision: this.state.revision + 1 }
      for (const listener of this.listeners) listener(this.state)
    }
    this.publish()
  }
  async refresh(): Promise<void> { await this.app.dataSet('notebookFiles').refresh(); this.publish() }
  close(): void { this.closed = true; this.stopData(); this.listeners.clear() }
}
export interface FileReadingTarget { repoId: string; path: string; syncId?: string }
export interface FileReadingSnapshot { config: AppConfig; file?: CoreOrgFile; repositoryName: string }
export class FileDataManager extends SnapshotDataManager<FileReadingSnapshot> {
  constructor(context: Context, target: FileReadingTarget) {
    super(context, async (config: AppConfig, workspace: CoreWorkspace): Promise<FileReadingSnapshot> => {
      let file: CoreOrgFile | undefined = undefined
      const coreRepo = (await workspace.repos()).find(repo => repo.id === target.repoId)
      const repository = config.repos.find(repo => repo.id === target.repoId || repo.rootDirectory === coreRepo?.rootDirectory)
      if (target.syncId) {
        if (!repository) throw new Error('此存储库已不存在')
        const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults, config.coreSettings)
        file = await repo.historyFile(target.syncId, target.path, false)
      } else {
        file = await NotebookService.open(config.repos, target.repoId, target.path, config.todoDefaults, config.coreSettings)
      }
      return { config, file, repositoryName: repositoryLabel(repository) }
    }, event => event.repoId === target.repoId && (event.files === null || !!event.files?.some(file => file.after.path === target.path) ||
      event.changes.some(change => change.before?.task.fullPath.file === target.path || change.after?.task.fullPath.file === target.path)),
      event => event.changeFiles.some(change => change.file.repoId === target.repoId && change.file.path === target.path))
  }
}
export interface SyncLogSnapshot { items: CoreSyncRecord[]; repositoryName: string; repoId: string }
export class SyncLogDataManager extends SnapshotDataManager<SyncLogSnapshot> {
  constructor(context: Context, repoId: string) {
    super(context, async (config: AppConfig): Promise<SyncLogSnapshot> => {
      const repository = config.repos.find(repo => repo.id === repoId)
      if (!repository) throw new Error('此存储库已不存在，请返回存储库列表')
      const items = await NativeCoreService.repositoryHistory(config.repos, repository, config.todoDefaults, config.coreSettings)
      items.sort((left: CoreSyncRecord, right: CoreSyncRecord): number => right.started_at - left.started_at)
      return { items, repositoryName: repositoryLabel(repository), repoId: repository.id }
    })
  }
}

export class SyncLogDetailDataManager extends SnapshotDataManager<CoreSyncRecordDetail> {
  constructor(context: Context, repoId: string, syncId: string) {
    super(context, async (config: AppConfig): Promise<CoreSyncRecordDetail> => {
      const repository = config.repos.find(repo => repo.id === repoId)
      if (!repository) throw new Error('此存储库已不存在')
      const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults, config.coreSettings)
      return await repo.historyDetail(syncId)
    }, (): boolean => false)
  }
}
