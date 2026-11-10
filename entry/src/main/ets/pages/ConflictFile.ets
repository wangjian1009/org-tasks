import { util } from '@kit.ArkTS'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/Controls'
import { OrgFilePreviewView, OrgFilePreviewNavigation } from '../components/OrgFilePreviewView'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, CoreConflictPreview, CoreConflictPreviewChanges, CoreConflictTarget, CoreFileConflict,
  CoreOrgFile, CoreTask, CoreTaskOperation, CoreTaskOperationGroup, CoreWorkspace, NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor, repositoryLabel } from '../ui/Theme'

interface ConflictParams { repoId: string; path: string }
interface ConflictPlacement { label: string; target: CoreConflictTarget }

@Entry
@Component
struct ConflictFile {
  @State file: CoreOrgFile | undefined = undefined
  @State baseFile: CoreOrgFile | undefined = undefined
  @State previewFile: CoreOrgFile | undefined = undefined
  @State conflicts: CoreFileConflict[] = []
  @State changes: CoreConflictPreviewChanges | undefined = undefined
  @State content: string = ''
  @State html: string = ''
  @State path: string = ''
  @State fileContext: string = ''
  @State sourceMode: boolean = false
  @State showBefore: boolean = false
  @State loading: boolean = true
  @State saving: boolean = false
  @State message: string = ''
  @State stale: boolean = false
  @State drawerOpen: boolean = false
  @State listVisible: boolean = false
  @State targetsVisible: boolean = false
  @State placements: ConflictPlacement[] = []
  @State selectedId: string = ''
  @State selectedNode: CoreTask | undefined = undefined
  @State stagedAction: string = ''
  @State manuallyEdited: boolean = false
  @State changeIndex: number = 0
  @State renderRevision: number = 0
  private navigation: OrgFilePreviewNavigation = new OrgFilePreviewNavigation()
  private pendingGroup: CoreTaskOperationGroup | undefined = undefined
  private preview: CoreConflictPreview | undefined = undefined
  private workspace: CoreWorkspace | undefined = undefined
  private requestId: number = 0
  private coreRepoId: string = ''
  private configRepoId: string = ''
  private sourceRootDirectory: string = ''
  private initialized: boolean = false
  private childEditor: boolean = false
  private leaving: boolean = false

  onPageShow() {
    if (!this.initialized) this.load()
    else if (this.preview) { this.childEditor = false; this.refreshPreview() }
    else this.load()
  }
  aboutToDisappear() {
    if (this.childEditor) return
    this.requestId++
    const preview = this.preview
    if (preview) preview.discard().catch((): void => {})
  }
  onBackPress(): boolean {
    if (this.saving) return true
    if (this.targetsVisible) { this.targetsVisible = false; return true }
    if (this.listVisible) { this.listVisible = false; return true }
    if (this.navigation.closePanel()) return true
    this.exit()
    return true
  }

  async load() {
    const request = ++this.requestId
    this.loading = true
    this.message = ''
    let createdPreview: CoreConflictPreview | undefined = undefined
    try {
      const params = this.getUIContext().getRouter().getParams() as ConflictParams
      const context = this.getUIContext().getHostContext()!
      const config = await AppConfigService.load(context, false)
      const repository = config.repos.find(repo => repo.id === params.repoId)
      if (!repository) throw new Error('此存储库已不存在')
      const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
      const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults)
      await workspace.setPreviewRoot(`${context.cacheDir}/org-conflict-previews`)
      const file = await repo.file(params.path)
      let conflicts = file.conflicts()
      let baseFile = file
      let previewFile: CoreOrgFile | undefined = undefined
      if (conflicts.length > 0) {
        createdPreview = await workspace.createConflictPreview({ file: file.fullPath, conflictId: conflicts[0].id, sourceVersion: file.fileVersion })
        baseFile = await createdPreview.sourceFile()
        previewFile = await createdPreview.file()
        conflicts = await createdPreview.conflicts()
      }
      if (request !== this.requestId) { if (createdPreview) await createdPreview.discard(); return }
      this.workspace = workspace
      this.coreRepoId = repo.id
      this.configRepoId = repository.id
      this.sourceRootDirectory = repository.rootDirectory
      this.path = params.path
      this.fileContext = `${repositoryLabel(repository)} / ${params.path}`
      this.sourceMode = config.fileDisplayMode === 'source'
      this.file = file
      this.conflicts = conflicts
      this.preview = createdPreview
      this.baseFile = baseFile
      this.previewFile = previewFile
      this.changes = undefined
      this.stale = false
      this.selectedId = ''
      this.showBefore = false
      this.selectedNode = undefined
      this.stagedAction = ''
      this.initialized = true
      this.present(baseFile)
    } catch (e) {
      if (createdPreview) await createdPreview.discard().catch((): void => {})
      if (request === this.requestId) this.message = `读取冲突文件失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally { if (request === this.requestId) this.loading = false }
  }

  present(file: CoreOrgFile) {
    this.content = util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(file.sourceBytes())
    this.html = file.renderHtml()
    this.renderRevision++
  }

  selectedConflict(): CoreFileConflict | undefined { return this.conflicts.find(item => item.id === this.selectedId) }
  mainChangeCount(): number { return this.changes?.changes.filter(change => change.area === 'main').length ?? 0 }
  canApply(): boolean {
    return !this.saving && !this.stale && !this.message && !!this.previewFile && !!this.stagedAction &&
      this.changes?.previewVersion === this.previewFile.fileVersion
  }

  reasonLabel(reason: string): string {
    switch (reason) {
      case 'modify': return '本地修改'
      case 'create': return '本地新增'
      case 'delete': return '本地删除'
      case 'modify-missing': return '原节点已消失'
      case 'missing-parent': return '父节点已消失'
      case 'reorder': return '顺序冲突'
      case 'structure': return '结构冲突'
      default: return '内容冲突'
    }
  }

  selectConflict(conflict: CoreFileConflict) {
    if (this.saving) return
    this.listVisible = false
    if (this.selectedId === conflict.id && this.preview && !this.stale) { this.navigation.focusChange(0); return }
    const action = conflict.availableActions.includes('useLocal') && !['reorder', 'structure'].includes(conflict.reason) ? 'useLocal' : ''
    this.confirmAbandon((): void => { this.prepare(conflict, action) })
  }

  confirmAbandon(action: () => void) {
    if (!this.manuallyEdited) { action(); return }
    this.getUIContext().showAlertDialog({ title: '放弃未应用的调整？',
      message: '本项手动调整仅保存在预览中，继续会放弃这些调整。已经应用的结果不受影响。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '放弃调整', action } })
  }

  async prepare(conflict: CoreFileConflict, action: string, chooseTarget: boolean = false) {
    if (!this.workspace || !this.file || this.saving) return
    const request = ++this.requestId
    const reusable = this.preview && !this.stagedAction && !this.manuallyEdited && !this.pendingGroup && !this.stale ? this.preview : undefined
    this.saving = true
    this.message = ''
    this.stale = false
    this.selectedNode = undefined
    this.changes = undefined
    this.stagedAction = ''
    this.changeIndex = 0
    this.manuallyEdited = false
    this.pendingGroup = undefined
    try {
      const preview = reusable ?? await this.workspace.createConflictPreview({ file: this.file.fullPath,
        conflictId: conflict.id, sourceVersion: this.file.fileVersion })
      if (request !== this.requestId) { await preview.discard(); return }
      this.preview = preview
      this.selectedId = conflict.id
      const copied = await preview.file()
      this.baseFile = await preview.sourceFile()
      this.previewFile = copied
      this.showBefore = false
      this.present(copied)
      const copiedConflict = (await preview.conflicts()).find(item => item.id === conflict.id)
      if (!copiedConflict) throw new Error('冲突点已变化，请重新读取')
      if (action === 'discard') await this.stage('discard')
      else if (action === 'useLocal') {
        if (!chooseTarget && copiedConflict.suggestedTarget) await this.stage('useLocal', copiedConflict.suggestedTarget)
        else this.openTargets()
      } else this.changes = await preview.changes()
    } catch (e) {
      this.handleError(e as CoreBridgeError, '创建预览失败')
      // 失败可能发生在替换旧槽位之后，不继续使用旧的文件投影。
      if (this.preview) {
        try { this.previewFile = await this.preview.file() } catch (_) { this.preview = undefined; this.previewFile = undefined }
      }
    } finally { if (request === this.requestId) this.saving = false }
  }

  async stage(action: 'discard' | 'useLocal', target?: CoreConflictTarget) {
    const preview = this.preview
    const file = this.previewFile
    if (!preview || !file || !this.workspace) return
    const group: CoreTaskOperationGroup = {
      operations: [{ type: 'ConfilictSelection', data: { path: file.fullPath, id: this.selectedId, action, target } }],
      fileVersions: [{ repoId: file.repoId, file: file.path, version: file.fileVersion }], queueRepoIds: []
    }
    await this.workspace.executeTaskOperations(group)
    this.stagedAction = action
    await this.refreshPreview(false)
  }

  changeChoice(action: 'discard' | 'useLocal') {
    const conflict = this.selectedConflict()
    if (!conflict || this.saving) return
    if (action === 'useLocal' && ['reorder', 'structure'].includes(conflict.reason)) {
      this.getUIContext().showAlertDialog({ title: '用本地内容替换主树？',
        message: '将替换文件前言和全部普通内容，其他冲突点仍会保留。请在预览中核对全部变化后再应用。',
        primaryButton: { value: '取消', action: () => {} }, secondaryButton: { value: '查看替换预览', action: (): void => {
          this.confirmAbandon((): void => { this.prepareMainReplacement(conflict) })
        } } })
    } else this.confirmAbandon((): void => { this.prepare(conflict, action) })
  }

  async prepareMainReplacement(conflict: CoreFileConflict) {
    await this.prepare(conflict, '')
    if (!this.previewFile || this.saving || this.message) return
    this.saving = true
    try { await this.stage('useLocal', { type: 'replaceMain' }) }
    catch (e) { this.handleError(e as CoreBridgeError, '无法采用本地内容') }
    finally { this.saving = false }
  }

  openTargets() {
    const file = this.previewFile
    const conflict = this.selectedConflict()
    if (!file || !conflict) return
    if (['modify', 'delete'].includes(conflict.reason)) {
      this.placements = file.editableNodePaths().map(path => ({ label: path.titles.join(' / '), target: { type: 'existing', data: path } } as ConflictPlacement))
    } else {
      this.placements = file.insertionPositions().map(position => ({
        label: position.after ? `${position.after.titles.join(' / ')} 之后` : position.parent.titles.length > 0 ? `${position.parent.titles.join(' / ')} 下第一项` : '文件中第一个标题',
        target: { type: 'insert', data: position }
      } as ConflictPlacement))
    }
    this.targetsVisible = true
  }

  async chooseTarget(placement: ConflictPlacement) {
    if (this.saving) return
    this.saving = true
    this.message = ''
    this.targetsVisible = false
    try { await this.stage('useLocal', placement.target) }
    catch (e) { this.handleError(e as CoreBridgeError, '无法采用此目标') }
    finally { this.saving = false }
  }

  async refreshPreview(checkSource: boolean = true) {
    const preview = this.preview
    if (!preview || this.pendingGroup) return
    const request = this.requestId
    try {
      const file = await preview.file()
      const changes = await preview.changes()
      if (request !== this.requestId || preview.id !== this.preview?.id) return
      if (changes.previewVersion !== file.fileVersion) throw new Error('预览正在变化，请重新读取')
      if (this.previewFile && file.fileVersion !== this.previewFile.fileVersion && this.childEditor === false && checkSource) this.manuallyEdited = true
      this.previewFile = file
      this.changes = changes
      this.showBefore = false
      this.selectedNode = undefined
      this.present(file)
      if (checkSource && this.workspace) {
        const current = await this.workspace.fileAt(preview.sourcePath)
        if (request === this.requestId && current.fileVersion !== preview.sourceVersion) this.stale = true
      }
    } catch (e) { if (request === this.requestId) this.handleError(e as CoreBridgeError, '读取预览失败') }
  }

  async toggleBefore(before: boolean) {
    if (this.saving || !this.preview) return
    this.saving = true
    this.showBefore = before
    this.selectedNode = undefined
    try {
      const file = before ? this.baseFile : this.previewFile
      if (file) this.present(file)
    }
    catch (e) { this.handleError(e as CoreBridgeError, '切换预览失败') }
    finally { this.saving = false }
  }

  activateNode(index: number) {
    if (this.saving || this.showBefore || !this.previewFile || !this.stagedAction) return
    this.selectedNode = this.previewFile.nodes()[index]
  }

  async editSelected() {
    if (!this.selectedNode || this.saving || this.showBefore) return
    this.childEditor = true
    try { await this.getUIContext().getRouter().pushUrl({ url: 'pages/TaskEdit', params: { task: this.selectedNode, parents: this.selectedNode.fullPath.titles.slice(0, -1) } }) }
    catch (e) { this.childEditor = false; this.handleError(e as CoreBridgeError, '打开编辑失败') }
  }

  async applyPreview() {
    const preview = this.preview
    const file = this.previewFile
    if (!preview || !file || !this.canApply()) return
    this.saving = true
    this.message = ''
    let committed = false
    try {
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!, false)
      const repository = config.repos.find(item => item.id === this.configRepoId)
      if (!repository) throw new Error('此存储库已不存在')
      if (repository.rootDirectory !== this.sourceRootDirectory) throw new Error('仓库目录已改变，请重新读取')
      const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults)
      if (repo.id !== this.coreRepoId) throw new Error('仓库已改变，请重新读取')
      const group = this.pendingGroup ?? await preview.finish({ previewVersion: file.fileVersion })
      this.pendingGroup = group
      group.queueRepoIds = repository.webdavEnabled ? [repo.id] : []
      if (!this.workspace) throw new Error('工作区已失效')
      await this.workspace.executeTaskOperations(group)
      this.pendingGroup = undefined
      committed = true
      this.preview = undefined
      this.manuallyEdited = false
      await this.load()
    } catch (e) {
      this.handleError(e as CoreBridgeError, committed ? '已应用，重新读取失败' : '应用失败')
      if (!committed && this.workspace) {
        try { const current = await this.workspace.fileAt(preview.sourcePath); if (current.fileVersion !== preview.sourceVersion) this.stale = true }
        catch (_) { this.stale = true }
      }
    }
    finally { this.saving = false }
  }

  recreate() {
    if (this.saving) return
    this.getUIContext().showAlertDialog({ title: '重新创建预览？', message: '将放弃本项未应用的取舍与手动调整，并重新读取当前文件。',
      primaryButton: { value: '取消', action: () => {} }, secondaryButton: { value: '重新创建', action: (): void => { this.reloadDiscardingPreview() } } })
  }

  async reloadDiscardingPreview() {
    this.saving = true
    try { if (this.preview) await this.preview.discard(); this.preview = undefined; this.pendingGroup = undefined; this.manuallyEdited = false; await this.load() }
    catch (e) { this.handleError(e as CoreBridgeError, '重新读取失败') }
    finally { this.saving = false }
  }

  handleError(error: CoreBridgeError, prefix: string) {
    if (error.code === 'sourceVersionMismatch') this.stale = true
    this.message = `${prefix}：${coreErrorMessage(error)}`
  }

  confirmDiscard() {
    if (this.saving || !this.file || this.file.conflictIds.length === 0) return
    this.getUIContext().showAlertDialog({ title: '丢弃全部冲突？',
      message: `将移除“${this.path}”中的 ${this.file.conflictIds.length} 个冲突点，保留当前主树内容，并放弃尚未应用的预览调整。`,
      primaryButton: { value: '取消', action: () => {} }, secondaryButton: { value: '丢弃全部', action: (): void => { this.discardAll() } } })
  }

  async discardAll() {
    const file = this.file
    if (!file || file.conflictIds.length === 0 || this.saving) return
    this.saving = true
    this.message = ''
    try {
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!, false)
      const repository = config.repos.find(item => item.id === this.configRepoId)
      if (!repository) throw new Error('此存储库已不存在')
      if (repository.rootDirectory !== this.sourceRootDirectory) throw new Error('仓库目录已改变，请重新读取')
      const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults)
      if (repo.id !== this.coreRepoId) throw new Error('仓库已改变，请重新读取')
      if (this.preview) await this.preview.discard()
      this.preview = undefined
      await NativeCoreService.executeTaskOperations(config.repos, {
        operations: file.conflictIds.map((id: string): CoreTaskOperation => ({ type: 'ConfilictSelection', data: { path: file.fullPath, id, action: 'discard' } })),
        fileVersions: [{ repoId: this.coreRepoId, file: this.path, version: file.fileVersion }],
        queueRepoIds: repository.webdavEnabled ? [this.coreRepoId] : []
      }, config.todoDefaults)
      this.manuallyEdited = false
      await this.load()
    } catch (e) { this.handleError(e as CoreBridgeError, '丢弃失败') }
    finally { this.saving = false }
  }

  exit() {
    if (this.saving || this.leaving) return
    this.confirmAbandon((): void => { this.leave() })
  }
  async leave() {
    if (this.saving || this.leaving) return
    this.leaving = true
    this.requestId++
    try { if (this.preview) await this.preview.discard(); this.preview = undefined; await this.getUIContext().getRouter().back() }
    catch (e) { this.handleError(e as CoreBridgeError, '返回失败'); this.leaving = false }
  }

  @Builder
  conflictList() {
    Column() {
      Text(`冲突列表 · ${this.conflicts.length} 项`).fontSize(18).fontColor(UiColor.text).width('100%').padding({ bottom: 16 })
      List({ space: 0 }) {
        ForEach(this.conflicts, (conflict: CoreFileConflict) => {
          ListItem() {
            Column({ space: 6 }) {
              Text(conflict.title).fontSize(16).fontColor(conflict.id === this.selectedId ? UiColor.primary : UiColor.text).width('100%')
              Text(this.reasonLabel(conflict.reason)).fontSize(12).fontColor(UiColor.secondary).width('100%')
            }.width('100%').padding({ top: 14, bottom: 14 }).constraintSize({ minHeight: 64 })
              .onClick((): void => { this.selectConflict(conflict) }).enabled(!this.saving)
              .accessibilityText(`${conflict.title}，${this.reasonLabel(conflict.reason)}${conflict.id === this.selectedId ? '，已选中' : ''}`)
          }
        }, (conflict: CoreFileConflict) => conflict.id)
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%').padding(20)
  }

  @Builder
  targetList() {
    Column() {
      Text(['modify', 'delete'].includes(this.selectedConflict()?.reason ?? '') ? '选择处理目标' : '选择插入位置')
        .fontSize(18).fontColor(UiColor.text).width('100%').padding({ bottom: 16 })
      List() {
        ForEach(this.placements, (placement: ConflictPlacement, index: number) => {
          ListItem() { Text(placement.label).fontSize(15).fontColor(UiColor.text).width('100%').padding({ top: 14, bottom: 14 })
            .constraintSize({ minHeight: 48 }).onClick((): void => { this.chooseTarget(placement) }).enabled(!this.saving) }
        }, (placement: ConflictPlacement, index: number) => `${index}`)
      }.width('100%').layoutWeight(1)
      if (this.placements.length === 0) { Text('没有可用目标，可选择保留当前内容').fontSize(13).fontColor(UiColor.secondary) }
    }.width('100%').height('100%').padding(20)
  }

  build() {
    Column() {
      AppShell({ title: '解决冲突', back: true, drawerOpen: $drawerOpen, busy: this.saving,
        backAction: (): void => { this.exit() },
        actionIcon: $r('app.media.ui_more'), actionLabel: this.conflicts.length > 0 ? '更多操作' : '',
        actionMenuItems: [{ title: '丢弃全部冲突…', action: (): void => { this.confirmDiscard() } },
          { title: '文档目录', action: (): void => { this.navigation.openOutline() } }] }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在读取冲突文件', busy: true })
          } else if (!this.file) {
            EmptyState({ title: '无法处理冲突', detail: this.message, actionLabel: '重新读取', action: (): void => { this.load() } })
          } else {
            Text(this.fileContext).fontSize(12).fontColor(UiColor.secondary).width('100%').padding({ left: 20, right: 20, top: 8, bottom: 8 })
            if (this.message || this.stale) {
              Column({ space: 4 }) {
                Text(this.stale ? '原文件已变化，当前预览不能应用' : this.message).fontSize(13).fontColor(UiColor.error).width('100%')
                if (this.stale && this.message) { Text(this.message).fontSize(12).fontColor(UiColor.secondary).width('100%') }
                Row({ space: 12 }) {
                  Button('重新读取').fontSize(12).backgroundColor(Color.Transparent).fontColor(UiColor.primary).onClick((): void => { this.recreate() })
                  if (this.pendingGroup && !this.stale) { Button('重试应用').fontSize(12).backgroundColor(Color.Transparent).fontColor(UiColor.primary).onClick((): void => { this.message = ''; this.applyPreview() }) }
                  if (this.preview && !this.pendingGroup) { Button('重试预览').fontSize(12).backgroundColor(Color.Transparent).fontColor(UiColor.primary).onClick((): void => { this.message = ''; this.refreshPreview() }) }
                }
              }.width('100%').padding({ left: 20, right: 20, bottom: 8 })
            }
            if (this.preview && this.selectedId) {
              Row({ space: 12 }) {
                Button('当前文件').layoutWeight(1).fontSize(13).height(44).backgroundColor(this.showBefore ? UiColor.selected : UiColor.container)
                  .fontColor(this.showBefore ? UiColor.primary : UiColor.secondary).onClick((): void => { this.toggleBefore(true) })
                Button('合并预览').layoutWeight(1).fontSize(13).height(44).backgroundColor(!this.showBefore ? UiColor.selected : UiColor.container)
                  .fontColor(!this.showBefore ? UiColor.primary : UiColor.secondary).onClick((): void => { this.toggleBefore(false) })
              }.width('100%').padding({ left: 20, right: 20, bottom: 8 }).enabled(!this.saving)
            }
            OrgFilePreviewView({ content: this.content, renderedHtml: this.html, displayMode: this.sourceMode ? 'source' : 'rendered',
              fileContext: '', title: this.file.title() || this.path, revision: `${this.renderRevision}`,
              changes: this.changes, showBefore: this.showBefore, navigation: this.navigation,
              nodeActivated: (index: number): void => { this.activateNode(index) },
              failed: (message: string): void => { this.message = message } }).width('100%').layoutWeight(1)
            if (this.previewFile && this.stagedAction) {
              Row() {
                Text(this.mainChangeCount() === 0 ? '正文不变，将移除此冲突点' : `${this.mainChangeCount()} 处正文变化`).fontSize(12).fontColor(UiColor.secondary).layoutWeight(1)
                if (this.selectedNode) { Button('编辑此项').fontSize(12).height(44).onClick((): void => { this.editSelected() }).enabled(!this.saving && !this.showBefore) }
                Button('定位变化').fontSize(12).height(44).backgroundColor(Color.Transparent).fontColor(UiColor.primary)
                  .onClick((): void => { this.navigation.focusChange(this.changeIndex); this.changeIndex = (this.changeIndex + 1) % Math.max(1, this.mainChangeCount()) })
              }.width('100%').padding({ left: 20, right: 12 })
            }
            if (this.conflicts.length === 0) {
              Text('此文件的冲突已全部处理').fontSize(14).fontColor(UiColor.secondary).padding(12)
              Button('完成').height(44).margin({ bottom: 12 }).onClick((): void => { this.exit() })
            } else {
              Button(`冲突列表 · ${this.conflicts.length} 项${this.selectedConflict() ? `　${this.selectedConflict()!.title}` : '　点击选择'}`)
                .fontSize(13).fontColor(UiColor.text).backgroundColor(UiColor.container).width('100%').height(48)
                .onClick((): void => { this.listVisible = true }).enabled(!this.saving)
              if (this.selectedId) {
                Row({ space: 8 }) {
                  Button('保留当前').fontSize(12).height(44).layoutWeight(1).fontColor(this.stagedAction === 'discard' ? UiColor.primary : UiColor.secondary)
                    .backgroundColor(UiColor.container).onClick((): void => { this.changeChoice('discard') })
                  if (this.selectedConflict()?.availableActions.includes('useLocal')) {
                    Button(['reorder', 'structure'].includes(this.selectedConflict()?.reason ?? '') ? '本地替换主树' : '采用本地')
                      .fontSize(12).height(44).layoutWeight(1).fontColor(UiColor.primary).backgroundColor(UiColor.container)
                      .onClick((): void => { this.changeChoice('useLocal') })
                  }
                  Button('应用此项').fontSize(13).height(44).layoutWeight(1).enabled(this.canApply()).onClick((): void => { this.applyPreview() })
                }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 12 }).enabled(!this.saving)
                if (this.previewFile && !this.stagedAction && !['reorder', 'structure'].includes(this.selectedConflict()?.reason ?? '')) {
                  Button('选择处理目标或位置').fontSize(12).height(44).onClick((): void => { this.openTargets() }).enabled(!this.saving)
                }
              }
            }
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
      .bindSheet($$this.listVisible, this.conflictList, { height: '35%', detents: ['35%', '65%'], preferType: SheetType.BOTTOM, backgroundColor: UiColor.container, showClose: true })
      .bindSheet($$this.targetsVisible, this.targetList, { height: '65%', detents: ['65%', '85%'], preferType: SheetType.BOTTOM, backgroundColor: UiColor.container, showClose: true })
  }
}
