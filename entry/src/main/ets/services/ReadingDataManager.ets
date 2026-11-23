import { AppDataManager } from './AppDataManager'
import { Context } from '@kit.AbilityKit'
import { AppConfig } from '../models/OrgTask'
import { CoreRepo, CoreOrgFile, CoreOrgFileMetadata, CoreSyncRecord, CoreSyncRecordDetail,
  CoreTaskFileDeletion, CoreTaskOperationGroup, NativeCoreService } from './NativeCoreService'
import { NotebookGroup } from './NotebookService'
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
  async createFile(group: CoreTaskOperationGroup): Promise<void> {
    await this.app.dataSet('notebookFiles').submitOperationGroup(group, () => !this.closed, true)
  }
  async deleteFile(file: CoreOrgFileMetadata, allowed: () => boolean): Promise<void> {
    const dataSet = this.app.dataSet('notebookFiles')
    const snapshot = dataSet.data
    const current = snapshot?.type === 'file' && snapshot.result.find(item => item.repoId === file.repoId && item.path === file.path)
    if (!current || current.fileVersion !== file.fileVersion) throw new Error('文件已变化，请重新确认删除')
    const data: CoreTaskFileDeletion = { path: { repoId: file.repoId, file: file.path, titles: [] } }
    await dataSet.submitOperationGroup({
      operations: [{ type: 'FileDeletion', data }],
      fileVersions: [{ repoId: file.repoId, file: file.path, version: file.fileVersion }]
    }, () => !this.closed && allowed(), true)
  }
  close(): void { this.closed = true; this.stopData(); this.listeners.clear() }
}
export interface HistoryFileReadingTarget { repoId: string; path: string; syncId: string }
export interface HistoryFileReadingSnapshot { config: AppConfig; file: CoreOrgFile; repositoryName: string }
export class HistoryFileDataManager extends SnapshotDataManager<HistoryFileReadingSnapshot> {
  constructor(context: Context, target: HistoryFileReadingTarget) {
    super(context, async (config: AppConfig): Promise<HistoryFileReadingSnapshot> => {
      const repository = config.repos.find(repo => repo.id === target.repoId)
      if (!repository) throw new Error('此存储库已不存在')
      const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults, config.coreSettings)
      const file = await repo.historyFile(target.syncId, target.path, false)
      return { config, file, repositoryName: repositoryLabel(repository) }
    }, () => false, () => false)
  }
}
export interface SyncLogSnapshot { items: CoreSyncRecord[]; repositoryName: string; repoId: string }
export class SyncLogDataManager extends SnapshotDataManager<SyncLogSnapshot> {
  constructor(context: Context, repoId: string) {
    super(context, async (config: AppConfig): Promise<SyncLogSnapshot> => {
      const repository = config.repos.find(repo => repo.id === repoId)
      if (!repository) throw new Error('此存储库已不存在，请返回存储库列表')
      const items = await NativeCoreService.repositoryHistory(config.repos, repository, config.todoDefaults, config.coreSettings)
      items.sort((left: CoreSyncRecord, right: CoreSyncRecord): number => (right.started_at ?? -1) - (left.started_at ?? -1))
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
