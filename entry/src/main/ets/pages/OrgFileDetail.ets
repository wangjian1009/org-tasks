import { CenteredPanel } from '../components/controls/CenteredPanel'
import { PageNavigator } from '../services/PageNavigator'
import { DataManager, DataSet, DataSetEvent } from '../services/DataManager'
import { util } from '@kit.ArkTS'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/controls/EmptyState'
import { CoreBridgeError, CoreFileHeaderEntry, CoreFileHeaderValueChange, CoreOrgFile, CoreTask, CoreTaskPath, CoreTaskStructureEdit, CoreTitlePart, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'
import { OrgFileDocumentView, OrgFileDocumentNavigation } from '../components/OrgFileDocumentView'
import { InternalLinkProcessor, CallbackInternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { OrgFileReadingSection, projectReadingSections, reconcileProjectSections } from '../ui/OrgFileReadingPresentation'
import { TaskInlineSession } from '../services/TaskInlineService'
import { projectHeaderTitle, projectTagExpression } from '../ui/OrgFileHeaderPresentation'
import { toggleTaskTag, reconcileTaskTags } from '../ui/TaskTagFilterPresentation'
import { AppDataManager } from '../services/AppDataManager'
import { CoreNotificationsView } from '../components/CoreNotificationsView'
import { samePageValue } from '../services/PageDataEquality'
import { PopupMenuItem } from '../components/controls/PopupMenu'
import { OrgFileStructureMode, OrgFileStructureNodeKind, OrgFileStructureSheet,
  OrgFileStructureSheetController } from '../components/editors/OrgFileStructureSheet'
import { OrgFileEditSession, OrgFileEditView, OrgFileStructureSnapshot,
  projectEditIdle, projectStructureNodes } from '../ui/OrgFileStructurePresentation'
import { OrgFileEditBar } from '../components/OrgFileEditBar'
import { PageParameters } from '../services/PagePath'
import { HistoryFileDataManager, HistoryFileReadingSnapshot } from '../services/ReadingDataManager'
import { SnapshotState } from '../services/SnapshotDataManager'
import { syncLogTimeLabel } from '../ui/SyncLogPresentation'

interface OrgFileState { snapshot?: OrgFileSnapshot; message: string }
interface OrgFileSnapshot { file: CoreOrgFile | undefined; tasks: CoreTask[] }

@Entry
@Component
struct OrgFileDetail {
  @State title: string = ''
  @State titleParts: CoreTitlePart[] = []
  @State projectFile: boolean = true
  @State hasParent: boolean = PageNavigator.shared.path.depth > 1
  @State historyLabel: string = ''
  @State sections: OrgFileReadingSection[] = []
  @State headerEntries: CoreFileHeaderEntry[] = []
  @State headerVersion: string = ''
  @State categoryOptions: string[] = []
  @State category: string = ''
  @State tagOptions: string[] = []
  @State tagRows: string[][] = []
  @State tagGroups: string[][] = []
  @State selectedTags: string[] = []
  @State selectedCategory: string = ''
  @State matchedIds: string[] = []
  @State filtering: boolean = false
  @State filterMessage: string = ''
  private filterRequest: number = 0
  @State specialTags: string[] = []
  @State content: string = ''
  @State sourceMode: boolean = false
  @State loading: boolean = true
  @State refreshing: boolean = false
  @State message: string = ''
  @State refreshMessage: string = ''
  @State fileDeleted: boolean = false
  @State drawerOpen: boolean = false
  @State renderReady: boolean = false
  @State structureOpen: boolean = false
  private structureDialog?: CustomDialogController
  @State structureMode: OrgFileStructureMode = 'add'
  @State structureKind: OrgFileStructureNodeKind = 'task'
  @State structureSnapshot: OrgFileStructureSnapshot | undefined = undefined
  @State structureParent: string | null = null
  @State createdRow: string = ''
  @State structureMessage: string = ''
  private structureSheet: OrgFileStructureSheetController = new OrgFileStructureSheetController()
  @State structureEdit: OrgFileEditView = projectEditIdle()
  @State editBusy: boolean = false
  @State editVersion: string = ''
  @State editConflict: boolean = false
  @State editMessage: string = ''
  private editSession: OrgFileEditSession | undefined = undefined
  @State structureOrderParents: string[] = []
  private fileDataSet: DataSet | undefined = undefined
  private stopFile: (() => void) | undefined = undefined
  @StorageLink('taskInlineActive') @Watch('projectInlineChanged') projectInlineActive: string = ''
  private dataManager: DataManager | undefined = undefined
  private repoId: string = ''
  private path: string = ''
  private readingState: string = ''
  @State renderRevision: number = 0
  @State documentSession: string = ''
  private navigation: OrgFileDocumentNavigation = new OrgFileDocumentNavigation()
  private internalLinks: InternalLinkProcessor = new CallbackInternalLinkProcessor(
    async (target: string): Promise<boolean> =>
      this.pageVisible && !this.sourceMode && !this.refreshing && !this.structureEdit.active &&
        await this.ensureLinkSnapshot() && await this.navigation.isValidInternalLink(target),
    async (target: string): Promise<void> => {
      if (!this.pageVisible || this.sourceMode || this.refreshing || this.editSession) throw new Error('当前页面无法执行内部跳转')
      if (!await this.ensureLinkSnapshot()) throw new Error('内部链接索引尚未确认，请稍后重试')
      await this.navigation.followInternalLink(target)
    }
  )
  private historyManager: HistoryFileDataManager | undefined = undefined
  private latestHistory: SnapshotState<HistoryFileReadingSnapshot> | undefined = undefined
  private appliedHistoryRevision: number = -1
  private entryTaskRead: boolean = false
  @State entryTask: CoreTaskPath | undefined = undefined
  private loadRevision: number = 0
  private needsReload: boolean = false
  private fileVersion: string = ''
  private fileIdentity: string = ''
  private structurePending: boolean = false
  private pendingFile: OrgFileSnapshot | undefined = undefined
  private linkSnapshotDirty: boolean = false
  private linksRefreshing: boolean = false
  @State pageVisible: boolean = true

  aboutToDisappear(): void {
    this.structureDialog?.close(); this.structureDialog = undefined
    this.stopFile?.(); this.stopFile = undefined
    this.dataManager?.close().catch((): void => { console.error('关闭项目数据集失败') })
    this.historyManager?.close()
  }
  onPageShow() {
    this.pageVisible = true
    this.hasParent = PageNavigator.shared.path.depth > 1
    const reload = this.needsReload; this.needsReload = false
    this.loadFile(reload); this.refreshDocument()
  }
  // 页面退出时使进行中的文件读取失效。
  onPageHide() {
    this.needsReload = this.loading || this.refreshing
    this.pageVisible = false
    this.loadRevision++
    this.filterRequest++
    this.filtering = false
  }
  onBackPress(): boolean {
    if (this.fileDeleted) { this.leaveDeletedFile(); return true }
    if (this.structureOpen || this.structureDialog) { this.structureSheet.back(); return true }
    if (this.editSession || this.editBusy) { this.backStructureEdit(); return true }
    if (this.navigation.closePanel()) return true
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    if (!this.hasParent && this.sourceMode) { this.toggleSource(); return true }
    if (TaskInlineSession.active()) { this.leaveFile(); return true }
    PageNavigator.shared.back(this.getUIContext())
    return true
  }

  async leaveFile() {
    if (await TaskInlineSession.end(true)) PageNavigator.shared.back(this.getUIContext())
  }

  async rememberReading(): Promise<string> {
    const version = this.fileVersion
    const identity = this.fileIdentity
    try {
      const state = await this.navigation.captureReadingState()
      if (version === this.fileVersion && identity === this.fileIdentity && state) this.readingState = state
    } catch (_) { /* 阅读组件已离开时保留最近一次有效位置。 */ }
    return this.readingState
  }

  async toggleSource() {
    if (this.refreshing || this.editSession || !await TaskInlineSession.end(false)) return
    if (!this.sourceMode) await this.rememberReading()
    this.navigation.closePanel()
    this.sourceMode = !this.sourceMode
  }

  async refreshFile() {
    if (this.refreshing || this.editSession || !await TaskInlineSession.end(true)) return
    await this.rememberReading()
    await this.loadFile(true)
  }

  async loadFile(force: boolean = false) {
    if (!this.pageVisible) return
    const params = this.getUIContext().getRouter().getParams() as PageParameters
    if (!this.entryTaskRead) {
      this.entryTaskRead = true
      this.entryTask = params.focusTask
    }
    if (params.syncId) {
      await this.loadHistory(params, params.syncId, force)
      return
    }
    const repoId = params.repoId || '', path = params.path || ''
    if (force || this.message || this.refreshMessage || !this.dataManager || !this.dataManager.hasValidScope() || this.repoId !== repoId || this.path !== path) {
      this.refreshing = true; this.filterRequest++; this.filtering = false
      this.stopFile?.(); this.dataManager?.close().catch((): void => {})
      this.pendingFile = undefined
      if (this.repoId !== repoId || this.path !== path) { this.selectedTags = []; this.selectedCategory = '' }
      this.repoId = repoId; this.path = path
      const context = this.getUIContext().getHostContext()!
      this.dataManager = DataManager.create(context, 'project', [{
          name: 'tasks', query: { type: 'task', repoIds: [repoId], query: { expression: '',
            includeFiles: [{ repoId, path }], fullFiles: [{ repoId, path }], includeIgnored: true } }
        }, { name: 'matches', query: { type: 'task', repoIds: [repoId], query: {
          expression: this.tagExpression(), categories: this.categoryQuery(), includeFiles: [{ repoId, path }], includeIgnored: true
        } } }, { name: 'metadata', query: { type: 'file', query: { includeFiles: [{ repoId, path }], includeIgnored: true } } }],
        { cache: false, parent: AppDataManager.shared(context).manager })
      const manager = this.dataManager
      const fileDataSet = manager.dataSet('tasks')
      this.fileDataSet = fileDataSet
      const stopTasks = fileDataSet.subscribe((event: DataSetEvent): void => {
        if (fileDataSet !== this.fileDataSet) return
        if (event.removedFiles?.some(file => file.repoId === repoId && file.path === path)) {
          this.pendingFile = undefined
          this.fileDeleted = true
          return
        }
        if (event.added?.length || event.removed?.length || event.updated?.length) this.linkSnapshotDirty = true
        if (event.type === 'error' && !event.targetKey) this.applyFileState({ message: fileDataSet.error })
        else if (event.structureChanged) { this.structurePending = true; this.refreshDocument() }
        if (event.type === 'complete' && this.pendingFile) this.applyPendingFile()
      })
      const stopMatches = manager.dataSet('matches').subscribe((): void => { this.refreshDocument() })
      const stopMetadata = manager.dataSet('metadata').subscribe((): void => { this.refreshDocument() })
      const stopCategories = manager.dataSet('categories').subscribe((): void => { this.refreshDocument() })
      const stopFiles = manager.subscribeFiles(async result => {
        if (manager !== this.dataManager || result.name !== 'tasks') return
        if (!this.pageVisible) { this.needsReload = true; return }
        const data = fileDataSet.data
        if (this.linksRefreshing && result.fullFiles[0] && data?.type === 'task') {
          const sections = projectReadingSections(result.fullFiles[0], data.result.tasks)
          for (const section of sections) if (section.node) section.key = fileDataSet.taskKey(section.node.id)
          this.sections = sections
          this.linkSnapshotDirty = false
          return
        }
        this.pendingFile = { file: result.fullFiles[0], tasks: data?.type === 'task' ? data.result.tasks : [] }
        await this.applyPendingFile()
      })
      this.stopFile = (): void => { stopTasks(); stopMatches(); stopMetadata(); stopCategories(); stopFiles() }
      try {
        const results = await manager.start()
        if (manager !== this.dataManager) return
        const file = results.find(result => result.name === 'tasks')?.fullFiles[0]
        const data = fileDataSet.data
        await this.applyFileState({ snapshot: { file, tasks: data?.type === 'task' ? data.result.tasks : [] }, message: '' })
      } catch (error) {
        if (manager === this.dataManager) await this.applyFileState({ message: (error as Error).message })
      }
    }
  }

  private async loadHistory(params: PageParameters, syncId: string, force: boolean): Promise<void> {
    if (!this.historyManager) {
      this.repoId = params.repoId || ''
      this.path = params.path || ''
      const label = `历史备份 · ${params.backupPath || this.path}`
      const time = params.backupTime ? ` · ${syncLogTimeLabel(params.backupTime)}` : ''
      this.historyLabel = `${label}\n${params.repositoryName || ''}${time}`
      this.historyManager = new HistoryFileDataManager(this.getUIContext().getHostContext()!,
        { repoId: this.repoId, path: this.path, syncId })
      this.stopFile = this.historyManager.subscribe((state: SnapshotState<HistoryFileReadingSnapshot>): void => {
        if (!params.repositoryName && state.value) {
          this.historyLabel = `${label}\n${state.value.repositoryName}${time}`
        }
        this.latestHistory = state
        this.applyHistory()
      })
    }
    if (force) await this.historyManager.refresh()
    else await this.historyManager.start()
    this.applyHistory()
  }

  private applyHistory(): void {
    const state = this.latestHistory
    if (!this.pageVisible || !state || state.revision === this.appliedHistoryRevision || (!state.value && !state.message)) return
    this.appliedHistoryRevision = state.revision
    const file = state.value?.file
    if (!this.fileVersion && state.value) this.sourceMode = state.value.config.fileDisplayMode === 'source'
    const snapshot: OrgFileSnapshot = { file, tasks: file?.nodes() ?? [] }
    this.applyFileState({ snapshot, message: state.message })
  }

  tagExpression(): string { return projectTagExpression(this.selectedTags, this.tagGroups) }
  categoryQuery(): string[] { return this.selectedCategory ? [this.selectedCategory] : [] }

  async selectCategory(): Promise<void> {
    if (!await TaskInlineSession.end(true)) return
    this.selectedCategory = this.selectedCategory ? '' : this.category
    await this.updateTagQuery()
  }

  async selectTag(tag: string): Promise<void> {
    if (!await TaskInlineSession.end(true)) return
    this.selectedTags = tag ? toggleTaskTag({ tags: this.selectedTags, includeUntagged: false }, tag, this.tagGroups).tags : []
    await this.updateTagQuery()
  }

  async updateTagQuery(): Promise<void> {
    const request = ++this.filterRequest
    this.filtering = true; this.filterMessage = ''
    const manager = this.dataManager
    const matches = manager?.dataSet('matches')
    await matches?.setQuery({ type: 'task', repoIds: [this.repoId], query: {
      expression: this.tagExpression(), categories: this.categoryQuery(), includeFiles: [{ repoId: this.repoId, path: this.path }], includeIgnored: true
    } })
    if (request !== this.filterRequest || manager !== this.dataManager || !this.pageVisible) return
    this.filtering = false
    this.filterMessage = matches?.error ?? ''
    this.refreshDocument()
  }

  refreshDocument(): void {
    if (!this.pageVisible || this.refreshing || !this.fileVersion) return
    const metadata = this.dataManager?.dataSet('metadata').data
    if (metadata?.type === 'file' && metadata.result[0]) {
      const file = metadata.result[0]
      this.headerEntries = file.headerEntries
      this.headerVersion = file.fileVersion
    }
    const categories = this.dataManager?.dataSet('categories').data
    if (categories?.type === 'file') this.categoryOptions = Array.from(new Set<string>(categories.result
      .filter(file => file.repoId === this.repoId && !!file.category).map(file => file.category!))).sort()
    if (TaskInlineSession.active()) return
    if (metadata?.type === 'file' && metadata.result[0]) {
      const file = metadata.result[0]
      const expression = this.tagExpression()
      const selectedCategory = this.selectedCategory
      this.projectFile = file.projectName != null
      this.title = this.projectFile ? projectHeaderTitle(file.category ?? '', file.projectName!) : file.title || this.path
      this.titleParts = this.projectFile ? [] : file.titleParts
      this.tagOptions = file.tagOptions.filter(tag => !this.specialTags.includes(tag) && tag !== 'todo')
      this.tagRows = file.tagRows ?? [this.tagOptions]
      this.tagGroups = file.tagGroups
      this.category = file.category ?? ''
      if (this.selectedCategory && this.selectedCategory !== this.category) this.selectedCategory = ''
      this.selectedTags = reconcileTaskTags({ tags: this.selectedTags, includeUntagged: false }, this.tagOptions, this.tagGroups).tags
      if (expression !== this.tagExpression() || selectedCategory !== this.selectedCategory) { this.updateTagQuery(); return }
    }
    const matches = this.dataManager?.dataSet('matches').data
    if (matches?.type === 'task' && !this.filtering && !this.filterMessage) {
      const ids = matches.result.tasks.map(task => task.id)
      if (!samePageValue(this.matchedIds, ids)) this.matchedIds = ids
    }
    if (!this.structurePending) return
    const data = this.fileDataSet?.data
    if (data?.type !== 'task') return
    const sections = reconcileProjectSections(this.sections, data.result.tasks,
      (task: CoreTask): string => this.fileDataSet!.taskKey(task.id))
    if (sections !== this.sections) this.sections = sections
    this.updateStructureOrderParents(data.result.tasks)
    this.structurePending = false
  }

  async saveHeader(changes: CoreFileHeaderValueChange[], version: string): Promise<void> {
    if (!this.fileDataSet || !this.pageVisible) throw new Error('项目页面已离开')
    await this.fileDataSet.updateFileHeader({ repoId: this.repoId, path: this.path }, changes, version)
    this.refreshDocument()
  }

  private currentStructure(): OrgFileStructureSnapshot {
    const dataSet = this.fileDataSet
    const confirmed = dataSet?.getConfirmed()?.data
    if (!dataSet || confirmed?.type !== 'task' || !this.pageVisible) throw new Error('项目文件尚未载入')
    const metadata = this.dataManager?.dataSet('metadata').getConfirmed()?.data
    const file = metadata?.type === 'file' ? metadata.result[0] : undefined
    const tasks = confirmed.result.tasks
    const version = tasks[0]?.fileVersion ?? file?.fileVersion ?? this.headerVersion
    if (!version) throw new Error('项目文件版本尚未确认')
    const matched = this.selectedTags.length || this.selectedCategory ? this.matchedIds : null
    return { file: { repoId: this.repoId, file: this.path, titles: [] }, version, title: this.title,
      nodes: projectStructureNodes(tasks, (task: CoreTask): string => dataSet.taskKey(task.id), matched),
      hasConflict: file?.hasConflict ?? false }
  }

  private async openStructure(mode: OrgFileStructureMode, row: string = '', kind: OrgFileStructureNodeKind = 'task'): Promise<void> {
    if (this.structureOpen || this.structureDialog || this.editSession || this.editBusy || this.refreshing || this.sourceMode || !await TaskInlineSession.end(true)) return
    this.structureMessage = ''
    try {
      await this.fileDataSet?.settle()
      if (this.structureOpen || this.structureDialog || this.editSession || this.editBusy || this.refreshing || this.sourceMode || !this.pageVisible) return
      const snapshot = this.currentStructure()
      const parent = row ? snapshot.nodes.find(node => node.row === row) : undefined
      if (row && !parent) throw new Error('父节点已移除，请重新选择')
      if (mode === 'add' && parent?.task) return
      if (mode === 'order' && snapshot.nodes.filter(node => node.parent === (parent?.id ?? null)).length < 2) return
      this.navigation.closePanel()
      this.structureParent = parent?.id ?? null
      this.structureMode = mode
      this.structureKind = kind
      this.structureSnapshot = snapshot
      if (mode === 'add') this.structureOpen = true
      else {
        this.structureDialog = new CustomDialogController({
          builder: CenteredPanel({ content: (): void => { this.structurePanel() } }),
          customStyle: true, alignment: DialogAlignment.Center, autoCancel: false,
          onWillDismiss: (): void => { this.structureSheet.back() }
        })
        this.structureDialog.open()
      }
    } catch (error) { this.structureMessage = coreErrorMessage(error as CoreBridgeError) }
  }

  private async commitStructure(snapshot: OrgFileStructureSnapshot, edits: CoreTaskStructureEdit[]): Promise<string[]> {
    const dataSet = this.fileDataSet
    if (!dataSet || (!this.structureOpen && !this.structureDialog) || !this.pageVisible) throw new Error('项目页面已离开')
    const rows = await dataSet.commitStructure({ file: snapshot.file, fileVersion: snapshot.version, edits })
    return dataSet === this.fileDataSet && this.pageVisible ? rows : []
  }

  private async beginStructureEdit(row: string = ''): Promise<void> {
    if (this.editSession || this.editBusy || this.structureOpen || this.structureDialog || this.refreshing || this.sourceMode || !this.pageVisible) return
    this.editBusy = true
    this.structureMessage = ''
    const dataSet = this.fileDataSet
    const scope = dataSet?.identity
    try {
      if (!await TaskInlineSession.end(true)) return
      await dataSet?.settle()
      if (!this.pageVisible || dataSet !== this.fileDataSet || scope !== dataSet?.identity || this.structureOpen || this.structureDialog || this.refreshing || this.sourceMode) return
      const snapshot = this.currentStructure()
      if (row && !snapshot.nodes.some(node => node.row === row)) throw new Error('节点已移除，请重新选择')
      this.navigation.closePanel()
      this.drawerOpen = false
      this.editSession = new OrgFileEditSession(snapshot, row)
      this.editVersion = snapshot.version
      this.editConflict = false
      this.editMessage = ''
      this.publishStructureEdit()
      if (row) void this.navigation.locateEditSource(row)
    } catch (error) { this.structureMessage = coreErrorMessage(error as CoreBridgeError) }
    finally { this.editBusy = false }
  }

  private publishStructureEdit(): void {
    this.structureEdit = this.editSession?.view() ?? projectEditIdle()
  }

  private staleStructureEdit(): boolean {
    return this.editConflict || (!!this.headerVersion && !!this.editVersion && this.headerVersion !== this.editVersion)
  }

  private canEditStructure(): boolean {
    return !!this.editSession && !this.editBusy && !this.staleStructureEdit() && this.pageVisible && !this.fileDeleted
  }

  private exitStructureEdit(): void {
    this.editSession = undefined
    this.editVersion = ''
    this.editConflict = false
    this.editMessage = ''
    this.publishStructureEdit()
  }

  private backStructureEdit(): void {
    if (this.editSession && !this.editBusy) this.exitStructureEdit()
  }

  private reorderStructureRow(row: string, sibling: string): void {
    if (!this.canEditStructure()) return
    const edit = this.editSession?.reorder(row, sibling)
    if (edit) void this.commitStructureMove(edit)
  }

  private async commitStructureMove(edit: CoreTaskStructureEdit): Promise<void> {
    const session = this.editSession, dataSet = this.fileDataSet
    if (!session || !dataSet || !this.canEditStructure()) return
    this.editBusy = true
    this.editMessage = ''
    try {
      const snapshot = session.snapshot
      if (this.currentStructure().version !== snapshot.version) { this.editConflict = true; return }
      await dataSet.commitStructure({ file: snapshot.file, fileVersion: snapshot.version, edits: [edit] })
      if (session !== this.editSession || !this.pageVisible || dataSet !== this.fileDataSet) return
      const confirmed = this.currentStructure()
      this.editSession = new OrgFileEditSession(confirmed)
      this.editVersion = confirmed.version
      this.publishStructureEdit()
    } catch (error) {
      this.editMessage = coreErrorMessage(error as CoreBridgeError)
      this.editConflict = this.editMessage.includes('版本')
    } finally { this.editBusy = false }
  }

  private async reloadStructure(force: boolean): Promise<OrgFileStructureSnapshot> {
    if (force) await this.dataManager?.refreshFiles('tasks')
    return this.currentStructure()
  }

  private async locateNewRow(row: string, reveal: boolean): Promise<void> {
    if (!this.pageVisible) return
    if (reveal && (this.selectedTags.length || this.selectedCategory)) {
      this.selectedTags = []
      this.selectedCategory = ''
      await this.updateTagQuery()
    }
    this.createdRow = await this.navigation.locateCreated(row, reveal) ? '' : row
  }

  private nodeStructureActions(row: string, canOrder: boolean): PopupMenuItem[] {
    const task = this.fileDataSet?.getTask(row)
    if (!task) return []
    const actions: PopupMenuItem[] = task.state ? [] : this.addStructureActions(row)
    actions.push({ title: '移动', icon: $r('app.media.ui_move_to'), action: (): void => { this.openStructure('move', row) } })
    actions.push({ title: '重构', icon: $r('app.media.ui_move_to'), action: (): void => { this.beginStructureEdit(row) } })
    if (canOrder) {
      actions.push({ title: '排序', icon: $r('app.media.ui_drag_handle'), action: (): void => { this.openStructure('order', row) } })
    }
    return actions
  }

  private updateStructureOrderParents(tasks: CoreTask[]): void {
    const nodes = projectStructureNodes(tasks, (task: CoreTask): string => this.fileDataSet!.taskKey(task.id), null)
    const counts = new Map<string | null, number>()
    for (const node of nodes) counts.set(node.parent, (counts.get(node.parent) ?? 0) + 1)
    const parents = nodes.filter(node => (counts.get(node.id) ?? 0) > 1).map(node => node.row)
    if (!samePageValue(this.structureOrderParents, parents)) this.structureOrderParents = parents
  }

  private async leaveDeletedFile(): Promise<void> {
    const ui = this.getUIContext()
    if (this.hasParent) await PageNavigator.shared.back(ui)
    else await PageNavigator.shared.openPrimary(ui, { url: 'pages/Files' })
  }

  private projectMenu(): PopupMenuItem[] {
    const actions: PopupMenuItem[] = []
    if (this.renderReady && !this.sourceMode && !this.historyLabel) {
      actions.push(...this.addStructureActions(''),
        { title: '重构', icon: $r('app.media.ui_move_to'), action: (): void => { this.beginStructureEdit() } })
    }
    const refresh: PopupMenuItem = { title: '刷新', icon: $r('app.media.ui_sync'), action: (): void => { this.refreshFile() } }
    if (this.sourceMode) {
      actions.push({ title: '文档', icon: $r('app.media.ui_document_outline'), action: (): void => { this.toggleSource() } }, refresh)
    } else {
      actions.push(refresh, { title: '原文', icon: $r('app.media.ui_body'), action: (): void => { this.toggleSource() } })
    }
    return actions
  }

  private addStructureActions(row: string): PopupMenuItem[] {
    return [
      { title: '任务', icon: $r('app.media.ui_add_task'), action: (): void => { this.openStructure('add', row, 'task') } },
      { title: '章节', icon: $r('app.media.ui_add_section'), action: (): void => { this.openStructure('add', row, 'section') } }
    ]
  }

  @Builder
  structurePanel() {
    if (this.structureSnapshot) {
      OrgFileStructureSheet({ mode: this.structureMode, snapshot: this.structureSnapshot, initialParent: this.structureParent,
        initialKind: this.structureKind,
        liveVersion: this.headerVersion, controller: this.structureSheet,
        close: (): void => { this.structureOpen = false; this.structureDialog?.close(); this.structureDialog = undefined },
        save: (snapshot: OrgFileStructureSnapshot, edits: CoreTaskStructureEdit[]): Promise<string[]> => this.commitStructure(snapshot, edits),
        reload: (force: boolean): Promise<OrgFileStructureSnapshot> => this.reloadStructure(force),
        created: (row: string): void => { this.locateNewRow(row, false) } })
    }
  }

  projectInlineChanged(): void {
    if (TaskInlineSession.active()) return
    if (this.pendingFile) this.applyPendingFile()
    else this.refreshDocument()
  }

  private async applyPendingFile(): Promise<void> {
    if (TaskInlineSession.active() || this.fileDataSet?.snapshot()?.optimistic) return
    const snapshot = this.pendingFile
    this.pendingFile = undefined
    const current = this.fileDataSet?.data
    if (snapshot?.file && current?.type === 'task' && current.result.tasks.some(task => task.fileVersion !== snapshot.file!.fileVersion)) {
      this.dataManager?.refreshFiles('tasks').catch((): void => {})
      return
    }
    if (snapshot) await this.applyFileState({ snapshot, message: '' })
  }

  // 任务通知不含完整链接目标；实际跳转时才按需确认索引，普通修改不重读全文。
  private async ensureLinkSnapshot(): Promise<boolean> {
    if (!this.linkSnapshotDirty) return true
    if (!await TaskInlineSession.end(false) || !this.pageVisible || this.sourceMode || !this.dataManager) return false
    const manager = this.dataManager
    this.linksRefreshing = true
    try { await manager.refreshFiles('tasks') }
    finally { this.linksRefreshing = false }
    return manager === this.dataManager && this.pageVisible && !this.sourceMode && !this.linkSnapshotDirty
  }

  async applyFileState(state: OrgFileState): Promise<void> {
    if (!this.pageVisible || TaskInlineSession.active() || (!state.snapshot && !state.message)) return
    const revision = ++this.loadRevision
    const hasSnapshot = this.fileVersion.length > 0
    this.refreshing = true
    if (hasSnapshot && !this.sourceMode) await this.rememberReading()
    if (revision !== this.loadRevision) return
    try {
      if (state.message) throw new Error(state.message)
      const snapshot = state.snapshot!
      const repoId = this.repoId, path = this.path
      const file = snapshot.file
      if (revision !== this.loadRevision) return
      if (!file) throw new Error('此文件已不存在，请返回。')
      const sections = projectReadingSections(file, snapshot.tasks)
      for (const section of sections) {
        if (section.node && this.fileDataSet) section.key = this.fileDataSet.taskKey(section.node.id)
      }
      const specialTags = file.specialTags()
      const identity = JSON.stringify([repoId, path])
      const session = this.fileDataSet?.identity ?? identity
      const changed = identity !== this.fileIdentity || file.fileVersion !== this.fileVersion || this.documentSession !== session
      const project = file.project()
      this.projectFile = project !== null && !this.historyLabel
      this.title = this.projectFile ? projectHeaderTitle(file.category() || '', project!) : file.title() || path
      this.titleParts = this.projectFile ? [] : file.titleParts()
      if (identity !== this.fileIdentity && !this.projectFile && !this.historyLabel && !this.entryTask) {
        const context = this.getUIContext().getHostContext()!
        this.sourceMode = AppDataManager.shared(context).configuration?.fileDisplayMode === 'source'
      }
      this.sections = sections
      this.updateStructureOrderParents(snapshot.tasks)
      this.structurePending = false
      this.linkSnapshotDirty = false
      this.headerEntries = file.headerEntries()
      this.headerVersion = file.fileVersion
      this.category = file.category() ?? ''
      this.specialTags = specialTags
      this.content = util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(file.sourceBytes())
      if (changed) {
        if (identity !== this.fileIdentity) this.readingState = ''
        this.fileIdentity = identity
        this.fileVersion = file.fileVersion
        this.documentSession = session
        this.renderReady = false
        this.renderRevision++
      }
      this.message = ''
      this.refreshMessage = ''
    } catch (e) {
      if (revision !== this.loadRevision) return
      const message = `读取文件失败：${coreErrorMessage(e as CoreBridgeError)}`
      if (hasSnapshot) this.refreshMessage = `${message}。当前保留上次读取的内容。`
      else this.message = message
    } finally {
      if (revision === this.loadRevision) { this.loading = false; this.refreshing = false; this.refreshDocument() }
    }
  }

  build() {
    Column() {
      AppShell({ title: this.title || (this.hasParent ? '文件' : '项目'), titleParts: this.titleParts,
        titleIcon: this.projectFile ? '' : $r('app.media.ui_folder'), activeRoute: 'pages/OrgFileDetail',
        back: this.hasParent, drawerOpen: $drawerOpen,
        pullToSync: !this.historyLabel, pullDisabled: this.refreshing || this.fileDeleted || this.structureOpen || this.structureEdit.active,
        busy: this.editBusy || this.structureEdit.active,
        backAction: (): void => { this.onBackPress() },
        secondaryActionIcon: $r('app.media.ui_document_outline'),
        secondaryActionLabel: this.renderReady && !this.sourceMode && !this.refreshing && !this.structureEdit.active ? '文档目录' : '',
        secondaryAction: (): void => { this.navigation.openOutline() },
        actionIcon: $r('app.media.ui_more'),
        actionLabel: this.loading || this.message || this.refreshing || this.fileDeleted || this.structureEdit.active ? '' :
          this.projectFile ? '更多项目操作' : '更多文档操作',
        actionMenuItems: this.projectMenu() }) {
        Column() {
          if (!this.historyLabel) { CoreNotificationsView({ disabled: this.refreshing }) }
          if (this.fileDeleted) {
            EmptyState({ title: '文件已删除', actionLabel: '返回', action: (): void => { this.leaveDeletedFile() } })
          } else if (this.loading) {
            EmptyState({ title: '正在打开文件', busy: true })
          } else if (this.message) {
            EmptyState({ title: '无法打开文件', detail: this.message, actionLabel: '重试', action: (): void => { this.loadFile(true) } })
          } else {
            if (this.refreshing) {
              Row({ space: 8 }) {
                LoadingProgress().width(16).height(16).color(UiColor.primary)
                Text('正在刷新文件').fontSize(12).fontColor(UiColor.secondary)
              }.width('100%').padding({ left: 20, top: 8, bottom: 8 })
            }
            if (this.refreshMessage) {
              Text(this.refreshMessage).fontSize(12).fontColor(UiColor.error).width('100%').padding(12)
                .onClick((): void => { this.loadFile() })
            }
            if (this.filtering) { Text('正在筛选').fontSize(12).fontColor(UiColor.secondary).padding(8) }
            if (this.filterMessage) {
              Text(`筛选失败：${this.filterMessage}，点击重试`).fontSize(12).fontColor(UiColor.error).padding(8)
                .onClick((): void => { this.updateTagQuery() })
            }
            if (this.structureMessage) {
              Text(this.structureMessage).fontSize(13).fontColor(UiColor.error).width('100%').padding(12)
            }
            if (this.createdRow && !this.sourceMode && !this.structureEdit.active) {
              Row() {
                Text('已添加').fontSize(14).fontColor(UiColor.text).layoutWeight(1)
                Button(this.selectedTags.length || this.selectedCategory ? '清除筛选并定位' : '展开父项并定位')
                  .fontColor(UiColor.primary).backgroundColor(Color.Transparent)
                  .onClick((): void => { this.locateNewRow(this.createdRow, true) })
              }.width('100%').padding({ left: 16, right: 16 })
            }
            Stack() {
              ForEach([this.documentSession], (identity: string) => {
              OrgFileDocumentView({ dataSet: this.fileDataSet, sections: this.sections, matchedIds: this.matchedIds,
                focusTask: this.entryTask, focusConsumed: (): void => { this.entryTask = undefined },
                readOnly: !!this.historyLabel, fileContext: this.historyLabel,
                tagFiltered: this.selectedTags.length > 0 || this.selectedCategory.length > 0,
                headerEntries: this.headerEntries, headerVersion: this.headerVersion, categoryOptions: this.categoryOptions, tagOptions: this.tagOptions,
                beforeHeaderEdit: async (): Promise<boolean> => TaskInlineSession.end(true),
                saveHeader: (changes: CoreFileHeaderValueChange[], version: string): Promise<void> => this.saveHeader(changes, version),
                selectedTags: this.selectedTags, category: this.category, selectedCategory: this.selectedCategory,
                toggleTag: (tag: string): void => { this.selectTag(tag) }, toggleCategory: (): void => { this.selectCategory() }, specialTags: this.specialTags,
                revision: `${this.documentSession}:${this.fileIdentity}:${this.renderRevision}`, navigation: this.navigation,
                internalLinkProcessor: this.internalLinks,
                structureOrderParents: this.structureOrderParents,
                structureActions: (row: string, canOrder: boolean): PopupMenuItem[] => this.nodeStructureActions(row, canOrder),
                edit: this.structureEdit, editBusy: this.editBusy || this.staleStructureEdit(),
                reorderNode: (row: string, sibling: string): void => { this.reorderStructureRow(row, sibling) },
                readingState: this.readingState, showing: this.pageVisible && !this.sourceMode && !this.refreshing,
                scrolled: (offset: number): void => { this.readingState = JSON.stringify({ scroll: offset }) },
                ready: (): void => { this.renderReady = true } })
                .width('100%').height('100%').visibility(this.sourceMode ? Visibility.None : Visibility.Visible)
              }, (identity: string) => identity)
              if (this.sourceMode) {
                Scroll() {
                  Column({ space: 8 }) {
                    if (this.historyLabel) {
                      Text(this.historyLabel).fontSize(12).fontColor(UiColor.secondary).width('100%')
                    }
                    Text(this.content || '空白 Org 文件').fontSize(14).fontFamily('monospace')
                      .fontColor(UiColor.text).width('100%').copyOption(CopyOptions.LocalDevice)
                  }.width('100%').padding(20)
                }.width('100%').height('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
              }
            }.width('100%').layoutWeight(1)
            if (this.structureEdit.active) {
              OrgFileEditBar({ busy: this.editBusy, stale: this.staleStructureEdit(),
                message: this.editMessage,
                cancel: (): void => { this.backStructureEdit() } })
            }
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
      .bindSheet($$this.structureOpen, this.structurePanel, {
        height: 244, preferType: SheetType.BOTTOM, backgroundColor: UiColor.container, showClose: false,
        keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_RESIZE,
        onWillDismiss: (): void => { this.structureSheet.back() }
      })
  }
}
