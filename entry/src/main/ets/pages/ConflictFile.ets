import { util } from '@kit.ArkTS'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/Controls'
import { OrgFilePreviewView, OrgFilePreviewNavigation } from '../components/OrgFilePreviewView'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, CoreConflictPreview, CoreConflictPreviewChanges, CoreConflictPreviewProjection, CoreConflictTarget, CoreFileConflict,
  CoreOrgFile, CoreTask, CoreTaskOperation, CoreTaskOperationGroup, CoreTitlePart, CoreWorkspace, NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor, repositoryLabel } from '../ui/Theme'
import { ConflictTargetNode, ConflictTargetRow, conflictTargetTree, conflictTargetRows } from '../ui/ConflictTargetTree'

interface ConflictParams { repoId: string; path: string }

@Entry
@Component
struct ConflictFile {
  @State file: CoreOrgFile | undefined = undefined
  @State baseFile: CoreOrgFile | undefined = undefined
  @State previewFile: CoreOrgFile | undefined = undefined
  @State conflicts: CoreFileConflict[] = []
  @State changes: CoreConflictPreviewChanges | undefined = undefined
  @State projection: CoreConflictPreviewProjection | undefined = undefined
  @State beforeText: string = ''
  @State afterText: string = ''
  @State comparisonLoading: boolean = false
  @State content: string = ''
  @State html: string = ''
  @State path: string = ''
  @State title: string = ''
  @State titleParts: CoreTitlePart[] = []
  @State fileContext: string = ''
  @State sourceMode: boolean = false
  @State loading: boolean = true
  @State saving: boolean = false
  @State message: string = ''
  @State stale: boolean = false
  @State drawerOpen: boolean = false
  @State targetsVisible: boolean = false
  @State targetRoot: ConflictTargetNode | undefined = undefined
  @State expandedTargetKeys: string[] = []
  @State detailsExpanded: boolean = true
  @State selectedId: string = ''
  @State selectedNode: CoreTask | undefined = undefined
  @State stagedAction: string = ''
  @State manuallyEdited: boolean = false
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
  @State selectedTarget: CoreConflictTarget | undefined = undefined
  private restoredPosition: number | undefined = undefined

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
    if (this.navigation.closePanel()) return true
    this.exit()
    return true
  }

  async load(selectFirst: boolean = true) {
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
      this.title = file.title() || this.path
      this.titleParts = file.titleParts()
      this.fileContext = `${repositoryLabel(repository)} / ${params.path}`
      this.sourceMode = config.fileDisplayMode === 'source'
      this.file = file
      this.conflicts = conflicts
      this.preview = createdPreview
      this.baseFile = baseFile
      this.previewFile = previewFile
      this.changes = undefined
      this.projection = undefined
      this.beforeText = ''
      this.afterText = ''
      this.selectedTarget = undefined
      this.targetRoot = undefined
      this.expandedTargetKeys = []
      this.targetsVisible = false
      this.manuallyEdited = false
      this.stale = false
      this.selectedId = ''
      this.selectedNode = undefined
      this.stagedAction = ''
      this.initialized = true
      this.present(baseFile)
      if (selectFirst && conflicts.length > 0) {
        this.selectedId = conflicts[0].id
        // 读取失败也保留主树、冲突标题和保留当前入口。
        try { await this.readProjection() }
        catch (e) { if (request === this.requestId) this.handleError(e as CoreBridgeError, '读取差异失败') }
      }
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

  presentProjection() {
    if (!this.projection) return
    this.content = this.projection.content
    this.html = this.projection.renderedHtml
    this.renderRevision++
  }

  async readProjection(target?: CoreConflictTarget) {
    const preview = this.preview
    const file = this.previewFile
    if (!preview || !file || !this.selectedId) return
    const request = this.requestId
    const conflictId = this.selectedId
    this.comparisonLoading = true
    try {
      const projection = await preview.project({ conflictId, previewVersion: file.fileVersion, target })
      if (request !== this.requestId || preview.id !== this.preview?.id || conflictId !== this.selectedId) return
      if (projection.conflictId !== conflictId || projection.workingVersion !== file.fileVersion) throw new Error('差异已失效，请重试')
      this.projection = projection
      this.changes = projection.changes
      this.beforeText = projection.beforeText
      this.afterText = projection.afterText
      this.presentProjection()
      if (projection.status === 'targetRequired') this.openTargets()
    } finally { if (request === this.requestId && conflictId === this.selectedId) this.comparisonLoading = false }
  }

  async retryPreview() {
    if (this.saving) return
    this.saving = true
    this.message = ''
    try {
      if (this.stagedAction) await this.refreshPreview()
      else await this.readProjection(this.selectedTarget)
    } catch (e) { this.handleError(e as CoreBridgeError, '读取差异失败') }
    finally { this.saving = false }
  }

  summaryText(before: boolean): string {
    if (this.comparisonLoading) return '正在读取…'
    if (!this.stagedAction && !this.projection) return '差异读取失败，请重试'
    if (!this.stagedAction && this.projection?.status === 'unavailable') return before ? '保留当前文件内容' : '候选材料不完整，仅可保留当前'
    if (!this.stagedAction && this.projection?.status === 'targetRequired') {
      return before ? '待选择目标后比较' : this.afterText.trim() || '本地删除意图，待选择目标'
    }
    if (this.mainChangeCount() === 0) return this.stagedAction === 'discard' ? '正文不变' : '与当前内容相同'
    return (before ? this.beforeText : this.afterText).trim() || (before ? '此处没有内容' : '此处内容将被删除')
  }

  selectedConflict(): CoreFileConflict | undefined { return this.conflicts.find(item => item.id === this.selectedId) }
  mainChangeCount(): number { return this.changes?.changes.filter(change => change.area === 'main').length ?? 0 }
  canApply(): boolean {
    return !this.saving && !this.stale && !this.message && !!this.previewFile && !!this.stagedAction &&
      this.changes?.previewVersion === this.previewFile.fileVersion
  }

  reasonLabel(reason: string): string {
    switch (reason) {
      case 'modify': return '本地与当前同时修改了内容，请确认采用哪一版。'
      case 'create': return '本地新增了此节点，请选择插入位置。'
      case 'delete': return '本地已删除此节点，当前仍有修改，请确认是否删除。'
      case 'modify-missing': return '原节点已消失，本地修改需要重新放置。'
      case 'missing-parent': return '原父节点已消失，请为本地内容选择放置位置。'
      case 'reorder': return '两端同时调整了节点顺序，请确认采用的结构。'
      case 'structure': return '文件结构发生冲突，请确认是否替换主树。'
      default: return '此处存在内容冲突，请核对应用前后的内容。'
    }
  }

  selectConflict(conflict: CoreFileConflict) {
    if (this.saving || this.stale || this.pendingGroup) return
    if (this.selectedId === conflict.id && this.preview && !this.stale) { this.navigation.focusChange(0); return }
    this.confirmAbandon((): void => { this.prepare(conflict, '') })
  }

  selectAdjacent(delta: number) {
    if (this.saving || this.stale || this.pendingGroup || this.conflicts.length === 0) return
    const current = this.conflicts.findIndex(item => item.id === this.selectedId)
    const index = current < 0 ? delta < 0 ? this.conflicts.length - 1 : 0 :
      (current + delta + this.conflicts.length) % this.conflicts.length
    this.selectConflict(this.conflicts[index])
  }

  confirmAbandon(action: () => void) {
    if (!this.manuallyEdited) { action(); return }
    this.getUIContext().showAlertDialog({ title: '放弃未应用的调整？',
      message: '本项手动调整仅保存在预览中，继续会放弃这些调整。已经应用的结果不受影响。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '放弃调整', fontColor: UiColor.error, action } })
  }

  async prepare(conflict: CoreFileConflict, action: string, target?: CoreConflictTarget) {
    if (!this.workspace || !this.file || this.saving) return
    const request = ++this.requestId
    const reusable = this.preview && !this.stagedAction && !this.manuallyEdited && !this.pendingGroup && !this.stale ? this.preview : undefined
    this.saving = true
    this.comparisonLoading = true
    this.message = ''
    this.stale = false
    this.selectedNode = undefined
    this.changes = undefined
    this.projection = undefined
    this.beforeText = ''
    this.afterText = ''
    this.selectedId = conflict.id
    this.selectedTarget = target
    this.targetsVisible = false
    this.targetRoot = undefined
    this.expandedTargetKeys = []
    this.detailsExpanded = true
    this.content = ''
    this.html = ''
    this.renderRevision++
    this.stagedAction = ''
    this.manuallyEdited = false
    this.pendingGroup = undefined
    try {
      const preview = reusable ?? await this.workspace.createConflictPreview({ file: this.file.fullPath,
        conflictId: conflict.id, sourceVersion: this.file.fileVersion })
      if (request !== this.requestId) { await preview.discard(); return }
      this.preview = preview
      this.selectedId = conflict.id
      const copied = await preview.file()
      const base = await preview.sourceFile()
      const pending = await preview.conflicts()
      if (request !== this.requestId || preview.id !== this.preview?.id) return
      this.baseFile = base
      this.previewFile = copied
      this.present(copied)
      const copiedConflict = pending.find(item => item.id === conflict.id)
      if (!copiedConflict) throw new Error('冲突点已变化，请重新读取')
      if (action === 'discard') await this.stage('discard')
      else if (action === 'useLocal') {
        if (target || copiedConflict.suggestedTarget) await this.stage('useLocal', target ?? copiedConflict.suggestedTarget!)
        else { await this.readProjection(); this.openTargets() }
      } else await this.readProjection()
    } catch (e) {
      if (request !== this.requestId) return
      this.handleError(e as CoreBridgeError, '创建预览失败')
      // 失败可能发生在替换旧槽位之后，不继续使用旧的文件投影。
      if (this.preview) {
        try { this.previewFile = await this.preview.file() } catch (_) { this.preview = undefined; this.previewFile = undefined }
      }
    } finally { if (request === this.requestId) { this.saving = false; this.comparisonLoading = false } }
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

  applyLabel(): string {
    switch (this.selectedConflict()?.reason ?? '') {
      case 'create': return '插入'
      case 'delete': return '删除'
      case 'modify-missing':
      case 'missing-parent': return '放置'
      case 'reorder':
      case 'structure': return '替换主树'
      default: return '应用'
    }
  }

  async applyChoice() {
    if (this.saving || this.stale || this.pendingGroup) return
    const conflict = this.selectedConflict()
    if (!conflict?.availableActions.includes('useLocal') || this.comparisonLoading || this.message) return
    if (!this.stagedAction && this.projection?.status !== 'ready') { this.openTargets(); return }
    if (['reorder', 'structure'].includes(conflict.reason)) {
      this.getUIContext().showAlertDialog({ title: '用本地内容替换主树？',
        message: '将采用预览中的完整本地内容，替换文件前言和全部普通节点，其他冲突点继续保留。',
        primaryButton: { value: '取消', action: () => {} }, secondaryButton: { value: '替换主树',
          action: (): void => { this.submitChoice('useLocal', { type: 'replaceMain' }) } } })
    } else await this.submitChoice('useLocal', this.selectedTarget)
  }

  async discardChoice() {
    if (this.saving || this.stale || this.pendingGroup) return
    await this.submitChoice('discard')
  }

  async submitChoice(action: 'discard' | 'useLocal', target?: CoreConflictTarget) {
    if (this.saving || this.stale || this.pendingGroup || !this.previewFile || !this.selectedConflict()) return
    if (this.stagedAction && this.stagedAction !== action) {
      this.confirmAbandon((): void => { this.rebuildAndSubmit(action, target) })
      return
    }
    this.saving = true
    this.message = ''
    try { if (!this.stagedAction) await this.stage(action, target) }
    catch (e) { this.handleError(e as CoreBridgeError, '处理冲突失败') }
    finally { this.saving = false }
    if (!this.message) await this.applyPreview()
  }

  async rebuildAndSubmit(action: 'discard' | 'useLocal', target?: CoreConflictTarget) {
    const conflict = this.selectedConflict()
    if (!conflict) return
    await this.prepare(conflict, '')
    if (!this.message) await this.submitChoice(action, target)
  }

  openTargets() {
    const file = this.previewFile
    const conflict = this.selectedConflict()
    if (!file || !conflict || this.stale || this.pendingGroup) return
    if (!this.targetRoot) {
      this.targetRoot = conflictTargetTree(file, conflict.reason)
      this.expandedTargetKeys = [this.targetRoot.key, ...this.targetRoot.children.map(node => node.key)]
    }
    this.targetsVisible = true
    this.navigation.focusFooter()
  }

  targetRows(): ConflictTargetRow[] {
    return this.targetRoot ? conflictTargetRows(this.targetRoot, this.expandedTargetKeys) : []
  }

  toggleTargetBranch(row: ConflictTargetRow) {
    if (this.saving || !row.branch) return
    this.expandedTargetKeys = row.expanded ? this.expandedTargetKeys.filter(key => key !== row.key) :
      [...this.expandedTargetKeys, row.key]
  }

  selectedTargetLabel(): string {
    const target = this.selectedTarget ?? this.selectedConflict()?.suggestedTarget
    if (!target) return '选择放置位置'
    if (target.type === 'existing') return target.data.titles.join(' / ')
    if (target.type === 'insert') return target.data.after ? `${target.data.after.titles.join(' / ')} 之后` :
      target.data.parent.titles.length ? `${target.data.parent.titles.join(' / ')} 下第一项` : '文件中第一个标题'
    return '完整主树'
  }

  async chooseTarget(row: ConflictTargetRow) {
    if (this.saving || !row.target) return
    const request = this.requestId
    this.saving = true
    this.message = ''
    try {
      await this.readProjection(row.target)
      if (request === this.requestId) {
        this.selectedTarget = row.target
        this.targetsVisible = false
      }
    }
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
      this.selectedNode = undefined
      if (!this.stagedAction && this.selectedId) await this.readProjection(this.selectedTarget)
      else {
        this.changes = changes
        this.beforeText = changes.changes.map(change => change.lines.filter(line => line.kind === 'removed').map(line => line.text).join('')).join('\n')
        this.afterText = changes.changes.map(change => change.lines.filter(line => line.kind === 'added').map(line => line.text).join('')).join('\n')
        this.present(file)
      }
      if (checkSource && this.workspace) {
        const current = await this.workspace.fileAt(preview.sourcePath)
        if (request === this.requestId && current.fileVersion !== preview.sourceVersion) this.stale = true
      }
    } catch (e) { if (request === this.requestId) this.handleError(e as CoreBridgeError, '读取预览失败') }
  }

  async activateNode(index: number) {
    if (this.saving || this.stale || this.pendingGroup || !this.previewFile ||
      !Number.isInteger(index) || index < 0) return
    if (!this.stagedAction && this.projection?.status !== 'ready') return
    this.saving = true
    try {
      if (!this.stagedAction) await this.stage('useLocal', this.selectedTarget ??
        (['reorder', 'structure'].includes(this.selectedConflict()?.reason ?? '') ? { type: 'replaceMain' } : undefined))
      this.selectedNode = this.previewFile.nodes()[index]
    } catch (e) { this.handleError(e as CoreBridgeError, '打开编辑失败') }
    finally { this.saving = false }
    if (!this.message && this.selectedNode) await this.editSelected()
  }

  async editSelected() {
    if (!this.selectedNode || this.saving) return
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
      const position = await this.navigation.capturePosition()
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
      this.restoredPosition = position
      await this.load(false)
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
      primaryButton: { value: '取消', action: () => {} }, secondaryButton: { value: '重新创建', fontColor: UiColor.error, action: (): void => { this.reloadDiscardingPreview() } } })
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
      primaryButton: { value: '取消', action: () => {} }, secondaryButton: { value: '丢弃全部', fontColor: UiColor.error, action: (): void => { this.discardAll() } } })
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
  comparisonCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.selectedConflict()?.title ?? '').fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(UiColor.text).layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.detailsExpanded ? '⌃' : '⌄').fontSize(18).fontColor(UiColor.secondary).width(32)
      }.width('100%').constraintSize({ minHeight: 44 })
        .onClick((): void => { this.detailsExpanded = !this.detailsExpanded })
        .accessibilityText(`${this.selectedConflict()?.title ?? ''}，${this.detailsExpanded ? '收起' : '展开'}冲突细节`)
      Text(this.reasonLabel(this.selectedConflict()?.reason ?? '')).fontSize(12).fontColor(UiColor.secondary).width('100%')
      if (this.detailsExpanded) {
        Row({ space: 8 }) {
          Column({ space: 4 }) {
            Text('− 应用前').fontSize(12).fontColor(UiColor.error).width('100%')
            Text(this.summaryText(true)).fontSize(13).fontColor(UiColor.text).width('100%')
              .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).copyOption(CopyOptions.LocalDevice)
          }.layoutWeight(1).padding(10).borderRadius(8).backgroundColor('#422B33').alignSelf(ItemAlign.Stretch)
          Column({ space: 4 }) {
            Text(this.projection?.status === 'targetRequired' ? '本地候选 · 待选目标' : '＋ 应用后')
              .fontSize(12).fontColor(this.projection?.status === 'targetRequired' ? UiColor.warning : UiColor.done).width('100%')
            Text(this.summaryText(false)).fontSize(13).fontColor(UiColor.text).width('100%')
              .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).copyOption(CopyOptions.LocalDevice)
          }.layoutWeight(1).padding(10).borderRadius(8).backgroundColor(this.projection?.status === 'targetRequired' ? UiColor.field : '#203D33')
            .alignSelf(ItemAlign.Stretch)
        }.width('100%').alignItems(VerticalAlign.Top)
        Row({ space: 8 }) {
          Button(this.applyLabel()).fontSize(13).height(44).layoutWeight(1).fontColor(UiColor.onPrimary)
            .backgroundColor(UiColor.primary)
            .enabled(this.selectedConflict()?.availableActions.includes('useLocal') === true && !this.comparisonLoading &&
              !this.message && this.projection?.status !== 'unavailable')
            .onClick((): void => { this.applyChoice() })
          Button('丢弃').fontSize(13).height(44).layoutWeight(1).fontColor(UiColor.text)
            .backgroundColor(UiColor.field).onClick((): void => { this.discardChoice() })
        }.width('100%').padding({ top: 8 }).enabled(!this.saving && !this.stale && !this.pendingGroup)
      }
    }.width('100%').padding(12).backgroundColor(UiColor.container).borderRadius(12)
      .accessibilityDescription('应用前后内容为预览，点击操作后提交当前冲突')
  }

  @Builder
  targetTree() {
    Column({ space: 8 }) {
      Text(['modify', 'delete'].includes(this.selectedConflict()?.reason ?? '') ? '选择对应节点' : '选择放置位置')
        .fontSize(15).fontColor(UiColor.text).width('100%')
      Text('展开父节点查看子节点，点击标题选择目标').fontSize(12).fontColor(UiColor.secondary).width('100%')
      Scroll() {
        Column() {
          ForEach(this.targetRows(), (row: ConflictTargetRow) => {
            Row({ space: 4 }) {
              Button(row.branch ? row.expanded ? '⌄' : '›' : '└').fontSize(16).width(36).height(44)
                .backgroundColor(Color.Transparent).fontColor(UiColor.secondary).enabled(row.branch && !this.saving)
                .accessibilityText(`${row.expanded ? '收起' : '展开'} ${row.label}`)
                .onClick((): void => { this.toggleTargetBranch(row) })
              Text(row.label).fontSize(14).fontColor(row.target ? UiColor.text : UiColor.secondary).layoutWeight(1)
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                .onClick((): void => { this.chooseTarget(row) }).enabled(!!row.target && !this.saving)
                .accessibilityText(`${row.label}，${row.target?.type === 'insert' && !row.key.endsWith(':after') ? '放在此节点下第一项' : '选择此目标'}`)
            }.width('100%').constraintSize({ minHeight: 44 }).padding({ left: Math.min(row.depth, 8) * 16, right: 4 })
          }, (row: ConflictTargetRow) => row.key)
        }.width('100%')
      }.width('100%').height(220)
    }.width('100%').padding(12).backgroundColor(UiColor.container).borderRadius(12)
  }

  @Builder
  detailsFooter() {
    if (this.preview && this.selectedId) {
      Column({ space: 12 }) {
        this.comparisonCard()
        if (this.targetsVisible) {
          this.targetTree()
        } else if (this.selectedTarget || this.selectedConflict()?.suggestedTarget) {
          Row() {
            Text('目标').fontSize(12).fontColor(UiColor.secondary).margin({ right: 12 })
            Text(this.selectedTargetLabel()).fontSize(13).fontColor(UiColor.primary).layoutWeight(1)
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('›').fontSize(20).fontColor(UiColor.primary).margin({ left: 8 })
          }.width('100%').constraintSize({ minHeight: 44 }).padding(12).borderRadius(10).backgroundColor(UiColor.container)
            .onClick((): void => { this.openTargets() }).enabled(!this.saving && !this.stale && !this.stagedAction)
        }
      }.width('100%').padding({ left: 20, right: 20, top: 12, bottom: 16 })
    }
  }

  build() {
    Column() {
      AppShell({ title: this.title || this.path || '文件', titleParts: this.titleParts, titleIcon: $r('app.media.ui_conflict_resolve'),
        back: true, drawerOpen: $drawerOpen, busy: this.saving,
        backAction: (): void => { this.exit() },
        actionIcon: $r('app.media.ui_more'), actionLabel: this.conflicts.length > 0 ? '更多操作' : '',
        actionMenuItems: [{ title: '丢弃全部冲突…', dangerous: true, action: (): void => { this.confirmDiscard() } },
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
                  if (this.preview && !this.pendingGroup) { Button('重试预览').fontSize(12).backgroundColor(Color.Transparent).fontColor(UiColor.primary).onClick((): void => { this.retryPreview() }) }
                }
              }.width('100%').padding({ left: 20, right: 20, bottom: 8 })
            }
            OrgFilePreviewView({ content: this.content, renderedHtml: this.html, displayMode: this.sourceMode ? 'source' : 'rendered',
              fileContext: '', title: this.file.title() || this.path, revision: `${this.renderRevision}`,
              changes: this.changes, navigation: this.navigation,
              flowContent: true, footer: this.detailsFooter,
              ready: (): void => {
                if (this.restoredPosition !== undefined) {
                  const position = this.restoredPosition
                  this.restoredPosition = undefined
                  this.navigation.restorePosition(position)
                }
              },
              nodeActivated: (index: number): void => { this.activateNode(index) },
              failed: (message: string): void => { this.message = message } }).width('100%').layoutWeight(1)
            if (this.conflicts.length === 0) {
              Text('此文件的冲突已全部处理').fontSize(14).fontColor(UiColor.secondary).padding(12)
              Button('完成').height(44).margin({ bottom: 12 }).onClick((): void => { this.exit() })
            } else {
              Row({ space: 8 }) {
                Button('‹').fontSize(22).height(44).width(48).backgroundColor(UiColor.container)
                  .fontColor(UiColor.primary).enabled(!this.saving && !this.stale && !this.pendingGroup && this.conflicts.length > 1)
                  .accessibilityText('上一个冲突').onClick((): void => { this.selectAdjacent(-1) })
                Text(`${this.selectedId ? this.conflicts.findIndex(item => item.id === this.selectedId) + 1 : '—'} / ${this.conflicts.length}`)
                  .fontSize(13).fontColor(UiColor.primary).layoutWeight(1).textAlign(TextAlign.Center)
                Button('›').fontSize(22).height(44).width(48).backgroundColor(UiColor.container)
                  .fontColor(UiColor.primary).enabled(!this.saving && !this.stale && !this.pendingGroup)
                  .accessibilityText('下一个冲突').onClick((): void => { this.selectAdjacent(1) })
              }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 12 })
                .gesture(PanGesture({ direction: PanDirection.Horizontal, distance: 32 }).onActionEnd((event: GestureEvent): void => {
                  this.selectAdjacent(event.offsetX < 0 ? 1 : -1)
                }))
            }
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
