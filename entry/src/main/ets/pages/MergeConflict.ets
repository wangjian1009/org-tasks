import { RepoConfig } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, CoreMergeChange, CoreMergeComparison, CoreMergeFileVersion, CoreMergeMode, CoreMergeResolution,
  CoreRepo, CoreWebDavSyncPolicy, coreErrorMessage, NativeCoreService } from '../services/NativeCoreService'
import { RepositorySyncService } from '../services/RepositorySyncService'
import { AppShell } from '../components/AppShell'
import { EmptyState, MessageBar } from '../components/Controls'
import { MergeTaskCard } from '../components/MergeTaskCard'
import { UiColor } from '../ui/Theme'

interface MergeParams { repoId: string; syncId: string }
interface MergeChoice { id: string; choice: string }

@Entry
@Component
struct MergeConflict {
  @State comparison: CoreMergeComparison | undefined = undefined
  @State choices: MergeChoice[] = []
  @State generation: number = 0
  @State loading: boolean = true
  @State saving: boolean = false
  @State completed: boolean = false
  @State message: string = ''
  @State backups: string[] = []
  @State drawerOpen: boolean = false
  private repo: CoreRepo | undefined = undefined
  private policy: CoreWebDavSyncPolicy | undefined = undefined

  aboutToAppear() { this.load() }
  onBackPress(): boolean { return this.saving }

  async load() {
    if (this.saving) return
    this.loading = true
    this.message = ''
    this.comparison = undefined
    this.choices = []
    this.backups = []
    try {
      const params = this.getUIContext().getRouter().getParams() as MergeParams
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      const repository = config.repos.find((repo: RepoConfig) => repo.id === params.repoId)
      if (!repository || !repository.webdavEnabled) throw new Error('WebDAV 存储库已移除或停用')
      const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults)
      const policy = new CoreWebDavSyncPolicy(repository.webdavUrl, repository.webdavUsername, repository.webdavPassword)
      const comparison = await policy.compareMerge(repo, params.syncId)
      this.repo = repo
      this.policy = policy
      this.choices = comparison.changes.map((change: CoreMergeChange) => ({ id: change.id, choice: '' } as MergeChoice))
      this.generation++
      this.comparison = comparison
    } catch (e) { this.message = `比较失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.loading = false }
  }

  choiceFor(id: string): string { return this.choices.find((item: MergeChoice) => item.id === id)?.choice || '' }
  choose(id: string, choice: CoreMergeResolution) {
    if (this.saving || !this.comparison) return
    this.choices = this.choices.map((item: MergeChoice) => ({ id: item.id, choice: item.id === id ? choice : item.choice } as MergeChoice))
  }
  remaining(): number { return this.choices.filter((item: MergeChoice) => !item.choice).length }
  ready(): boolean { return this.choices.every((item: MergeChoice) => item.choice.length > 0) }
  fileChanges(path: string): CoreMergeChange[] {
    return this.comparison?.changes.filter((change: CoreMergeChange) => change.path === path) || []
  }
  taskChanges(path: string): CoreMergeChange[] { return this.fileChanges(path).filter((change: CoreMergeChange) => !change.preamble) }
  preambleChanges(path: string): CoreMergeChange[] { return this.fileChanges(path).filter((change: CoreMergeChange) => change.preamble) }
  fileSummary(path: string): string {
    const tasks = this.taskChanges(path)
    return `新增 ${tasks.filter((change: CoreMergeChange) => change.kind === 'added').length} · 修改 ${tasks.filter((change: CoreMergeChange) => change.kind === 'modified').length} · 删除 ${tasks.filter((change: CoreMergeChange) => change.kind === 'deleted').length}`
  }
  removed(): number {
    return this.comparison?.changes.filter((change: CoreMergeChange) =>
      this.choiceFor(change.id) === CoreMergeResolution.Local && !change.local ||
      this.choiceFor(change.id) === CoreMergeResolution.Remote && !change.remote).length || 0
  }

  recompare() {
    if (!this.choices.some((item: MergeChoice) => item.choice.length > 0)) { this.load(); return }
    this.getUIContext().showAlertDialog({ title: '重新比较？', message: '本次尚未提交的接受与丢弃选择将清除。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '重新比较', action: (): void => { this.load() } } })
  }

  moreActions() {
    if (this.loading || this.saving || this.completed || !this.comparison) return
    this.getUIContext().showActionSheet({ title: '比较操作', message: '以远端文件为基准，逐项接受或丢弃本地变更', sheets: [
      { title: '重新比较', action: (): void => { this.recompare() } },
      { title: '全部丢弃本地变更…', action: (): void => { this.confirm(CoreMergeMode.AcceptRemote) } }
    ] })
  }

  confirm(mode: CoreMergeMode) {
    if (this.loading || this.saving || this.completed || !this.comparison) return
    if (mode === CoreMergeMode.MergeTasks && !this.ready()) return
    this.getUIContext().showAlertDialog({ title: mode === CoreMergeMode.AcceptRemote ? '全部丢弃本地变更？' : '应用任务选择？',
      message: mode === CoreMergeMode.AcceptRemote ? `备份已有的本地冲突文件后，完整采用这 ${this.comparison.files.length} 个文件的远端版本。`
        : `以远端文件为基准，应用已接受的本地变更，丢弃其余本地变更；其中 ${this.removed()} 项不保留。提交前备份已有的本地冲突文件。`,
      primaryButton: { value: '取消', action: () => {} }, secondaryButton: {
        value: mode === CoreMergeMode.AcceptRemote ? '备份并全部丢弃' : '备份并应用', action: (): void => { this.apply(mode) }
      } })
  }

  async apply(mode: CoreMergeMode) {
    const comparison = this.comparison
    const repo = this.repo
    const policy = this.policy
    if (this.saving || this.completed || !comparison || !repo || !policy) return
    this.saving = true
    this.message = ''
    try {
      const current = await AppConfigService.load(this.getUIContext().getHostContext()!)
      await NativeCoreService.workspaceFor(current.repos, current.todoDefaults)
      const changes = comparison.changes.map((change: CoreMergeChange) => ({ id: change.id, path: change.path,
        kind: change.kind, preamble: change.preamble, localChange: change.localChange, remoteChange: change.remoteChange,
        local: change.local, remote: change.remote,
        resolution: mode === CoreMergeMode.AcceptRemote ? null : this.choiceFor(change.id) as CoreMergeResolution } as CoreMergeChange))
      const selected: CoreMergeComparison = { syncId: comparison.syncId, repoId: comparison.repoId,
        repositoryVersion: comparison.repositoryVersion, endpointVersion: comparison.endpointVersion,
        mode, files: comparison.files, unchangedCount: comparison.unchangedCount, changes }
      const result = await policy.applyMerge(repo, selected)
      this.backups = result.backups.map((backup) => `${backup.path} → ${backup.backupPath}`)
      this.completed = result.result === 'succeeded'
      this.comparison = undefined
      this.message = this.completed ? '任务变更已处理，同步日志已保存新的文件快照。'
        : '部分文件未完成，已保留备份。请重新比较剩余冲突。'
      try { await RepositorySyncService.refreshConflicts(this.getUIContext().getHostContext()!) } catch (_) {}
    } catch (e) {
      this.comparison = undefined
      this.message = `合并失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally { this.saving = false }
  }

  @Builder
  taskCard(change: CoreMergeChange) {
    MergeTaskCard({ change, choice: this.choiceFor(change.id),
      onChoose: (choice: CoreMergeResolution): void => { this.choose(change.id, choice) } })
  }

  @Builder
  fileHeader(path: string) {
    Column({ space: 6 }) {
      Row() {
        Row({ space: 6 }) {
          Image($r('app.media.ui_folder')).width(18).height(18)
          Text(path).fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
        }.layoutWeight(1)
        Text(`${this.fileChanges(path).filter((change: CoreMergeChange) => !this.choiceFor(change.id)).length} 项待决定`)
          .fontSize(12).fontColor(UiColor.primary)
      }.width('100%')
      Text(this.fileSummary(path)).fontSize(12).fontColor(UiColor.secondary).width('100%')
    }.width('100%').padding({ top: 16, bottom: 10 })
  }

  @Builder
  submitBar() {
    Column({ space: 8 }) {
      Row() {
        Text(`已决定 ${this.choices.length - this.remaining()}/${this.choices.length} 项`).fontSize(12).fontColor(UiColor.secondary).layoutWeight(1)
        Text(`直接保留远端 ${this.comparison?.unchangedCount || 0} 个任务`).fontSize(12).fontColor(UiColor.secondary)
      }.width('100%')
      Button(this.saving ? '正在备份并应用…' : this.remaining() > 0 ? `还有 ${this.remaining()} 项待决定` : '备份并应用选择')
        .width('100%').height(44).fontSize(15).backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary)
        .enabled(this.ready() && !this.saving).onClick((): void => { this.confirm(CoreMergeMode.MergeTasks) })
    }.width('100%').padding({ left: 16, right: 16, top: 10, bottom: 12 }).backgroundColor(UiColor.container)
  }

  build() {
    Column() {
      AppShell({ title: '解决冲突', titleIcon: $r('app.media.ui_sync'), back: true, drawerOpen: $drawerOpen, busy: this.saving,
        actionIcon: $r('app.media.ui_more'), actionLabel: !this.loading && !this.completed && this.comparison ? '比较操作' : '',
        action: (): void => { this.moreActions() } }) {
        Column() {
          MessageBar({ message: this.message, error: !this.completed })
          if (this.loading) {
            EmptyState({ title: '正在分析任务变更', busy: true })
          } else if (this.completed) {
            Scroll() {
              Column({ space: 18 }) {
                Text('本次冲突已处理').fontSize(22).fontColor(UiColor.done)
                ForEach(this.backups, (backup: string) => {
                  Text(backup).fontSize(13).fontColor(UiColor.secondary).width('100%')
                })
                Button('返回列表').backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary).onClick((): void => { this.getUIContext().getRouter().back() })
              }.width('100%').padding(24)
            }.width('100%').layoutWeight(1)
          } else if (this.comparison) {
            Column() {
              List({ space: 10 }) {
                ForEach(this.comparison.files, (file: CoreMergeFileVersion) => {
                  ListItem() { this.fileHeader(file.path) }
                  ForEach(this.preambleChanges(file.path), (change: CoreMergeChange) => {
                    ListItem() { this.taskCard(change) }
                  }, (change: CoreMergeChange) => `${this.generation}:${change.id}`)
                  ForEach(this.taskChanges(file.path), (change: CoreMergeChange) => {
                    ListItem() { this.taskCard(change) }
                  }, (change: CoreMergeChange) => `${this.generation}:${change.id}`)
                  if (this.fileChanges(file.path).length === 0) {
                    ListItem() {
                      Text('该文件沿用远端内容，没有需要决定的本地变更。').fontSize(13).fontColor(UiColor.secondary).padding(12)
                    }
                  }
                }, (file: CoreMergeFileVersion) => `${this.generation}:${file.path}`)
              }.width('100%').layoutWeight(1).padding({ left: 16, right: 16, bottom: 16 })
              this.submitBar()
            }.width('100%').layoutWeight(1).enabled(!this.saving)
          } else {
            Scroll() {
              Column({ space: 12 }) {
                ForEach(this.backups, (backup: string) => {
                  Text(backup).fontSize(13).fontColor(UiColor.secondary).width('100%')
                })
                Button('重新比较').backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary).onClick((): void => { this.load() })
              }.width('100%').padding(24)
            }.width('100%').layoutWeight(1)
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
