import { util } from '@kit.ArkTS'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/Controls'
import { OrgContentView } from '../components/OrgContentView'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, CoreOrgFile, CoreTaskOperation, CoreTaskOperationGroup, NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'

interface ConflictParams { repoId: string; path: string }

@Entry
@Component
struct ConflictFile {
  @State file: CoreOrgFile | undefined = undefined
  @State content: string = ''
  @State html: string = ''
  @State path: string = ''
  @State sourceMode: boolean = false
  @State loading: boolean = true
  @State saving: boolean = false
  @State message: string = ''
  @State drawerOpen: boolean = false
  private requestId: number = 0
  private coreRepoId: string = ''
  private configRepoId: string = ''

  onPageShow() { this.load() }
  aboutToDisappear() { this.requestId++ }
  onBackPress(): boolean { return this.saving }

  async load() {
    const request = ++this.requestId
    this.loading = true
    this.message = ''
    this.file = undefined
    try {
      const params = this.getUIContext().getRouter().getParams() as ConflictParams
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!, false)
      const repository = config.repos.find((repo) => repo.id === params.repoId)
      if (!repository) throw new Error('此存储库已不存在')
      const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults)
      const file = await repo.file(params.path)
      if (request !== this.requestId) return
      this.coreRepoId = repo.id
      this.configRepoId = repository.id
      this.path = params.path
      this.sourceMode = config.fileDisplayMode === 'source'
      this.file = file
      this.content = util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(file.sourceBytes())
      this.html = file.renderHtml()
    } catch (e) {
      if (request === this.requestId) this.message = `读取冲突文件失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally { if (request === this.requestId) this.loading = false }
  }

  confirmDiscard() {
    if (this.saving || !this.file || this.file.conflictIds.length === 0) return
    this.getUIContext().showAlertDialog({ title: '丢弃全部冲突？',
      message: `将移除“${this.path}”中的 ${this.file.conflictIds.length} 个冲突点，保留远端主树内容。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '丢弃', action: (): void => { this.discardAll() } } })
  }

  async discardAll() {
    const file = this.file
    if (!file || file.conflictIds.length === 0 || this.saving) return
    this.saving = true
    this.message = ''
    let committed = false
    try {
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!, false)
      const repository = config.repos.find((repo) => repo.id === this.configRepoId)
      if (!repository) throw new Error('此存储库已不存在')
      const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults)
      if (repo.id !== this.coreRepoId) throw new Error('仓库已改变，请重新读取')
      const group: CoreTaskOperationGroup = {
        operations: file.conflictIds.map((id: string) => ({ type: 'ConfilictSelection', data: { id, action: 'discard' } } as CoreTaskOperation)),
        fileVersions: [{ repoId: this.coreRepoId, file: this.path, version: file.fileVersion }],
        queueRepoIds: repository.webdavEnabled ? [this.coreRepoId] : []
      }
      await NativeCoreService.executeTaskOperations(config.repos, group, config.todoDefaults)
      committed = true
      this.file = undefined
      await this.getUIContext().getRouter().back()
    } catch (e) {
      this.message = `${committed ? '已丢弃，返回失败' : '丢弃失败'}：${coreErrorMessage(e as CoreBridgeError)}`
    } finally { this.saving = false }
  }

  build() {
    Column() {
      AppShell({ title: '解决冲突', back: true, drawerOpen: $drawerOpen, busy: this.saving,
        actionLabel: this.file && this.file.conflictIds.length > 0 ? '丢弃全部冲突' : '', actionText: '丢弃',
        actionIcon: $r('app.media.ui_delete_record'), action: (): void => { this.confirmDiscard() } }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在读取冲突文件', busy: true })
          } else if (this.message) {
            EmptyState({ title: '无法处理冲突', detail: this.message, actionLabel: '重新读取', action: (): void => { this.load() } })
          } else if (this.file) {
            Text(this.path).fontSize(16).fontColor(UiColor.text).width('100%').padding(16)
            Text(this.file.conflictIds.length > 0 ? `${this.file.conflictIds.length} 个冲突点位于文件末尾，可通过右上角丢弃全部。` : this.file.hasConflict ? '冲突内容格式不完整，当前无法丢弃。' : '此文件已没有待处理冲突。')
              .fontSize(13).lineHeight(20).fontColor(UiColor.secondary).width('100%').padding({ left: 16, right: 16, bottom: 12 })
            if (this.sourceMode) {
              Scroll() {
                Text(this.content).fontSize(13).fontFamily('monospace').lineHeight(21).fontColor(UiColor.text)
                  .copyOption(CopyOptions.LocalDevice).width('100%').padding(16)
              }.width('100%').layoutWeight(1)
            } else {
              OrgContentView({ fragment: this.html, empty: this.content.length === 0 })
                .width('100%').layoutWeight(1)
            }
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
