import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/Controls'
import { MergeTaskCard } from '../components/MergeTaskCard'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, CoreMergeChange, CoreMergeResolution, CoreRepo, CoreSyncConflictComparison, CoreSyncConflictResolution, CoreSyncConflictChoice,
  NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'

interface ConflictParams { repoId: string; syncId?: string; path: string }
interface ConflictChoice { id: string; side: string }

// 一次只处理被点击日志中的一个文件；逐项选择不触发文件或网络写入。
@Entry
@Component
struct ConflictFile {
  @State comparison: CoreSyncConflictComparison | undefined = undefined
  @State choices: ConflictChoice[] = []
  @State loading: boolean = true
  @State saving: boolean = false
  @State message: string = ''
  @State pendingPath: string = ''
  @State drawerOpen: boolean = false
  @State generation: number = 0
  private repo: CoreRepo | undefined = undefined
  private requestId: number = 0

  aboutToAppear() { this.load() }
  aboutToDisappear() { this.requestId++; this.choices = []; this.comparison = undefined }
  onBackPress(): boolean { return this.saving }

  async load() {
    const request = ++this.requestId
    this.loading = true
    this.message = ''
    this.choices = []
    this.comparison = undefined
    try {
      const params = this.getUIContext().getRouter().getParams() as ConflictParams
      if (!params.syncId) {
        this.pendingPath = params.path
        return
      }
      this.pendingPath = ''
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!, false)
      const repository = config.repos.find((item) => item.id === params.repoId)
      if (!repository) throw new Error('此存储库已不存在')
      const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults)
      const comparison = await repo.compareConflict(params.syncId, params.path)
      if (request !== this.requestId) return
      this.repo = repo
      this.choices = comparison.changes.map((change: CoreMergeChange) => ({ id: change.key, side: '' } as ConflictChoice))
      this.generation++
      this.comparison = comparison
    } catch (e) {
      if (request === this.requestId) this.message = `比较失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally { if (request === this.requestId) this.loading = false }
  }

  choice(id: string): string { return this.choices.find((item: ConflictChoice) => item.id === id)?.side || '' }
  ready(): boolean { return this.comparison !== undefined && this.choices.every((item: ConflictChoice) => item.side.length > 0) }
  remaining(): number { return this.choices.filter((item: ConflictChoice) => !item.side).length }

  choose(id: string, side: CoreMergeResolution) {
    if (this.saving) return
    this.choices = this.choices.map((item: ConflictChoice) => ({ id: item.id, side: item.id === id ? side : item.side } as ConflictChoice))
  }

  async save() {
    const comparison = this.comparison
    const repo = this.repo
    if (!this.ready() || this.saving || !comparison || !repo) return
    this.saving = true
    this.message = ''
    try {
      const request: CoreSyncConflictResolution = { target: comparison.target,
        expectedLocalHash: comparison.localHash, expectedRemoteHash: comparison.remoteHash,
        expectedLocalMissing: comparison.localMissing,
        choices: comparison.changes.map((change: CoreMergeChange) => ({ key: change.key,
          side: this.choice(change.key) as CoreMergeResolution } as CoreSyncConflictChoice)) }
      await repo.resolveConflict(request)
      this.getUIContext().getRouter().back()
    } catch (e) {
      this.message = `保存失败：${coreErrorMessage(e as CoreBridgeError)}。请重新比较。`
      this.comparison = undefined
      this.choices = []
    } finally { this.saving = false }
  }

  build() {
    Column() {
      AppShell({ title: '解决冲突', back: true, drawerOpen: $drawerOpen, busy: this.saving }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在比较远端备份与本地文件', busy: true })
          } else if (this.pendingPath) {
            Text(this.pendingPath).fontSize(18).fontColor(UiColor.text).width('100%')
              .padding({ left: 20, right: 20, top: 20, bottom: 12 })
            EmptyState({ title: '此文件包含待处理的同步冲突' })
          } else if (this.comparison) {
            Text(this.comparison.target.path).fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
              .width('100%').padding({ left: 20, right: 20, top: 16, bottom: 8 })
            Text('远端：该次日志备份 · 本地：当前仓库文件\n返回将放弃本轮选择').fontSize(12).lineHeight(20).fontColor(UiColor.secondary)
              .width('100%').padding({ left: 20, right: 20, bottom: 12 })
            List({ space: 10 }) {
              ForEach(this.comparison.changes, (change: CoreMergeChange) => {
                ListItem() {
                  MergeTaskCard({ change, choice: this.choice(change.key),
                    onChoose: (side: CoreMergeResolution): void => { this.choose(change.key, side) } })
                }
              }, (change: CoreMergeChange) => `${this.generation}:${change.key}`)
              if (this.comparison.changes.length === 0) {
                ListItem() { Text('没有待选择项，可直接保存并解决。').fontSize(14).fontColor(UiColor.secondary).padding(12) }
              }
            }.width('100%').layoutWeight(1).padding({ left: 12, right: 12, bottom: 12 }).enabled(!this.saving)
            Column({ space: 8 }) {
              Text(`已选择 ${this.choices.length - this.remaining()} / ${this.choices.length}`).fontSize(13)
                .fontColor(UiColor.secondary).width('100%')
              Button(this.saving ? '正在保存…' : this.ready() ? '保存并解决' : '完成全部选择后保存')
                .width('100%').height(44).fontSize(15).backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary)
                .enabled(this.ready() && !this.saving).onClick((): void => { this.save() })
            }.width('100%').padding({ left: 20, right: 20, top: 8, bottom: 12 })
          } else {
            EmptyState({ title: '无法处理冲突', detail: this.message, actionLabel: '重新比较', action: (): void => { this.load() } })
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
