import { LengthMetrics, router } from '@kit.ArkUI'
import { RepoConfig } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, CoreMergeChange, CoreMergeComparison, CoreMergeMode, CoreMergeResolution,
  CoreRepo, CoreWebDavSyncPolicy, coreErrorMessage, NativeCoreService } from '../services/NativeCoreService'
import { AppShell } from '../components/AppShell'
import { EmptyState, MessageBar } from '../components/Controls'
import { UiColor } from '../ui/Theme'

interface MergeParams { repoId: string; syncId: string }
interface MergeRow { change: CoreMergeChange; choice: string; expanded: boolean }

@Entry
@Component
struct MergeConflict {
  @State rows: MergeRow[] = []
  @State fileCount: number = 0
  @State unchangedCount: number = 0
  @State loading: boolean = true
  @State saving: boolean = false
  @State completed: boolean = false
  @State message: string = ''
  @State backups: string[] = []
  @State drawerOpen: boolean = false
  private comparison: CoreMergeComparison | undefined = undefined
  private repo: CoreRepo | undefined = undefined
  private policy: CoreWebDavSyncPolicy | undefined = undefined

  aboutToAppear() { this.load() }
  onBackPress(): boolean { return this.saving }

  async load() {
    if (this.saving) return
    this.loading = true
    this.message = ''
    this.comparison = undefined
    this.rows = []
    try {
      const params = router.getParams() as MergeParams
      const config = await AppConfigService.load(getContext(this))
      const repository = config.repos.find((repo: RepoConfig) => repo.id === params.repoId)
      if (!repository || !repository.webdavEnabled) throw new Error('WebDAV 存储库已移除或停用')
      const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults)
      const policy = new CoreWebDavSyncPolicy(repository.webdavUrl, repository.webdavUsername, repository.webdavPassword)
      const comparison = await policy.compareMerge(repo, params.syncId)
      this.repo = repo
      this.policy = policy
      this.comparison = comparison
      this.fileCount = comparison.files.length
      this.unchangedCount = comparison.unchangedCount
      this.rows = comparison.changes.map((change: CoreMergeChange) => ({ change, choice: '', expanded: false } as MergeRow))
    } catch (e) { this.message = `比较失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.loading = false }
  }

  label(change: CoreMergeChange): string {
    switch (change.kind) {
      case 'modified': return '修改 · 请选择保留版本'
      case 'added': return '新增 · 远端独有项'
      default: return '删除 · 本地独有项'
    }
  }

  choose(id: string, choice: CoreMergeResolution) {
    this.rows = this.rows.map((row: MergeRow) => ({ change: row.change, expanded: row.expanded,
      choice: row.change.id === id ? choice : row.choice } as MergeRow))
  }

  toggle(id: string) {
    this.rows = this.rows.map((row: MergeRow) => ({ change: row.change, choice: row.choice,
      expanded: row.change.id === id ? !row.expanded : row.expanded } as MergeRow))
  }

  ready(): boolean { return this.rows.every((row: MergeRow) => row.choice.length > 0) }
  remaining(): number { return this.rows.filter((row: MergeRow) => !row.choice).length }

  removed(): number {
    return this.rows.filter((row: MergeRow) => row.choice === CoreMergeResolution.Remove ||
      row.choice === CoreMergeResolution.Local && !row.change.local ||
      row.choice === CoreMergeResolution.Remote && !row.change.remote).length
  }

  confirm(mode: CoreMergeMode) {
    if (this.loading || this.saving || this.completed || !this.comparison) return
    if (mode === CoreMergeMode.MergeTasks && !this.ready()) { this.message = '请先确认所有差异项'; return }
    this.getUIContext().showAlertDialog({ title: mode === CoreMergeMode.AcceptRemote ? '本次同步全部采用远端？' : '应用本次同步的合并？',
      message: mode === CoreMergeMode.AcceptRemote ? `先备份这 ${this.fileCount} 个冲突文件中已有的本地文件，再采用对应远端版本。`
        : `保留未变化任务，按选择合并 ${this.fileCount} 个文件；其中 ${this.removed()} 项不保留。提交前会备份已有的本地冲突文件。`,
      primaryButton: { value: '取消', action: () => {} }, secondaryButton: {
        value: mode === CoreMergeMode.AcceptRemote ? '备份并采用远端' : '备份并合并', action: (): void => { this.apply(mode) }
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
      const current = await AppConfigService.load(getContext(this))
      await NativeCoreService.workspaceFor(current.repos, current.todoDefaults)
      const changes = this.rows.map((row: MergeRow) => ({ id: row.change.id, path: row.change.path, kind: row.change.kind,
        local: row.change.local, remote: row.change.remote,
        resolution: mode === CoreMergeMode.AcceptRemote ? null : row.choice as CoreMergeResolution } as CoreMergeChange))
      const selected: CoreMergeComparison = { syncId: comparison.syncId, repoId: comparison.repoId,
        repositoryVersion: comparison.repositoryVersion, endpointVersion: comparison.endpointVersion,
        mode, files: comparison.files, unchangedCount: comparison.unchangedCount, changes }
      const result = await policy.applyMerge(repo, selected)
      this.backups = result.backups.map((backup) => `${backup.path} → ${backup.backupPath}`)
      this.completed = result.result === 'succeeded'
      this.comparison = undefined
      this.message = this.completed ? '本次同步的冲突已处理。返回后可继续同步其余文件。'
        : '部分文件未完成，原始文件已备份。请重新比较剩余冲突。'
    } catch (e) {
      this.comparison = undefined
      this.message = `合并失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally { this.saving = false }
  }

  @Builder
  choiceButton(row: MergeRow, label: string, choice: CoreMergeResolution) {
    Button(label).fontSize(13).height(38)
      .backgroundColor(row.choice === choice ? UiColor.primary : UiColor.selected)
      .fontColor(row.choice === choice ? Color.White : UiColor.onSelected)
      .onClick((): void => { this.choose(row.change.id, choice) })
  }

  @Builder
  taskRow(row: MergeRow) {
    Column({ space: 12 }) {
      Text(row.change.path).fontSize(12).fontColor(UiColor.secondary).width('100%')
      Text(this.label(row.change)).fontSize(13).fontColor(UiColor.primary).width('100%')
      Text(row.change.remote?.title || row.change.local?.title || '文件前言').fontSize(17).fontWeight(FontWeight.Medium)
        .fontColor(UiColor.text).width('100%')
      if (row.change.local) {
        Text('本地版本').fontSize(13).fontColor(UiColor.secondary).width('100%')
        Text(row.change.local.source || '（空）').fontSize(13).lineHeight(20).fontColor(UiColor.text)
          .width('100%').maxLines(row.expanded ? 10000 : 4).textOverflow({ overflow: TextOverflow.Ellipsis })
      } else { Text('本地无此项').fontSize(13).fontColor(UiColor.secondary).width('100%') }
      if (row.change.remote) {
        Text('远端版本').fontSize(13).fontColor(UiColor.secondary).width('100%')
        Text(row.change.remote.source || '（空）').fontSize(13).lineHeight(20).fontColor(UiColor.text)
          .width('100%').maxLines(row.expanded ? 10000 : 4).textOverflow({ overflow: TextOverflow.Ellipsis })
      } else { Text('远端无此项').fontSize(13).fontColor(UiColor.secondary).width('100%') }
      Button(row.expanded ? '收起内容' : '展开内容').fontSize(12).height(32).backgroundColor(Color.Transparent)
        .fontColor(UiColor.primary).onClick((): void => { this.toggle(row.change.id) })
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
        this.choiceButton(row, row.change.local ? '保留本地' : '不新增', CoreMergeResolution.Local)
        this.choiceButton(row, row.change.remote ? '保留远端' : '确认删除', CoreMergeResolution.Remote)
        if (row.change.local && row.change.remote) this.choiceButton(row, '不保留此项', CoreMergeResolution.Remove)
      }.width('100%')
    }.width('100%').padding(16).backgroundColor(UiColor.container).borderRadius(12)
  }

  build() {
    Column() {
      AppShell({ title: '合并任务', back: true, drawerOpen: $drawerOpen, busy: this.saving }) {
        Column() {
          MessageBar({ message: this.message, error: !this.completed })
          if (this.loading) {
            EmptyState({ title: '正在比较本次同步的任务', busy: true })
          } else if (this.completed) {
            Column({ space: 20 }) {
              Text('本次冲突已处理').fontSize(22).fontColor(UiColor.done)
              ForEach(this.backups, (backup: string) => {
                Text(backup).fontSize(13).fontColor(UiColor.secondary).width('100%')
              })
              Text('备份按同步分组，不参与 WebDAV 传输。').fontSize(13).fontColor(UiColor.secondary).width('100%')
              Button('返回同步').onClick((): void => { router.back() })
            }.width('100%').padding(24)
          } else if (this.comparison) {
            List({ space: 12 }) {
              ListItem() {
                Column({ space: 12 }) {
                  Text(`${this.fileCount} 个冲突文件`).fontSize(20).fontColor(UiColor.text).width('100%')
                  Text(`自动保留 ${this.unchangedCount} 条未变化任务 · 待确认 ${this.remaining()} 项`)
                    .fontSize(14).fontColor(UiColor.secondary).width('100%')
                  Text('以下是从本地内容采用远端内容时的新增、修改和删除候选，请选择保留方式。文件前言的差异也需确认。')
                    .fontSize(13).lineHeight(21).fontColor(UiColor.secondary).width('100%')
                  Text('同一任务优先按 Org ID 对应；没有 ID 时按标题层级对应。标题改名或重名时，请检查新增和删除项。')
                    .fontSize(13).lineHeight(21).fontColor(UiColor.secondary).width('100%')
                  Button('本次同步全部采用远端并备份').fontSize(14).width('100%').backgroundColor(UiColor.selected).fontColor(UiColor.onSelected)
                    .onClick((): void => { this.confirm(CoreMergeMode.AcceptRemote) })
                  Button('重新比较').fontSize(14).width('100%').backgroundColor(Color.Transparent).fontColor(UiColor.primary)
                    .onClick((): void => { this.load() })
                }.width('100%').padding(8)
              }
              ForEach(this.rows, (row: MergeRow) => {
                ListItem() { this.taskRow(row) }
              }, (row: MergeRow) => `${row.change.id}:${row.choice}:${row.expanded}`)
              ListItem() {
                Button('应用本次选择并备份').width('100%').height(48).backgroundColor(UiColor.primary)
                  .enabled(this.ready()).onClick((): void => { this.confirm(CoreMergeMode.MergeTasks) })
              }
            }.width('100%').layoutWeight(1).padding({ left: 16, right: 16, top: 16, bottom: 32 }).enabled(!this.saving)
          } else {
            Button('重新比较').margin(24).onClick((): void => { this.load() })
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
