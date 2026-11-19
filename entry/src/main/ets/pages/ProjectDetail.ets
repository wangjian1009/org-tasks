import { PageNavigator } from '../services/PageNavigator'
import { DataManager, DataSet, DataSetEvent } from '../services/DataManager'
import { util } from '@kit.ArkTS'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/controls/EmptyState'
import { OrgFilePreviewView, OrgFilePreviewNavigation } from '../components/OrgFilePreviewView'
import { CoreBridgeError, CoreFileHeaderEntry, CoreFileHeaderValueChange, CoreOrgFile, CoreTask, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'
import { ProjectDocumentView, ProjectDocumentNavigation } from '../components/ProjectDocumentView'
import { InternalLinkProcessor, CallbackInternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { ProjectReadingSection, projectReadingSections, reconcileProjectSections } from '../ui/ProjectReadingPresentation'
import { TaskInlineSession } from '../services/TaskInlineService'
import { projectHeaderTitle, projectTagExpression } from '../ui/ProjectHeaderPresentation'
import { toggleTaskTag, reconcileTaskTags } from '../ui/TaskTagFilterPresentation'
import { AppDataManager } from '../services/AppDataManager'
import { CoreNotificationsView } from '../components/CoreNotificationsView'

interface ProjectFileState { snapshot?: ProjectFileSnapshot; message: string }
interface ProjectFileSnapshot { file: CoreOrgFile | undefined; tasks: CoreTask[] }

interface ProjectParams { repoId?: string; path?: string }

@Entry
@Component
struct ProjectDetail {
  @State title: string = ''
  @State sections: ProjectReadingSection[] = []
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
  @State drawerOpen: boolean = false
  @State renderReady: boolean = false
  private fileDataSet: DataSet | undefined = undefined
  private stopFile: (() => void) | undefined = undefined
  @StorageLink('taskInlineActive') @Watch('projectInlineChanged') projectInlineActive: string = ''
  private dataManager: DataManager | undefined = undefined
  private repoId: string = ''
  private path: string = ''
  private readingState: string = ''
  @State renderRevision: number = 0
  @State documentSession: string = ''
  private navigation: ProjectDocumentNavigation = new ProjectDocumentNavigation()
  private internalLinks: InternalLinkProcessor = new CallbackInternalLinkProcessor(
    async (target: string): Promise<boolean> =>
      this.pageVisible && !this.sourceMode && !this.refreshing && await this.navigation.isValidInternalLink(target),
    async (target: string): Promise<void> => {
      if (!this.pageVisible || this.sourceMode || this.refreshing) throw new Error('当前页面无法执行内部跳转')
      await this.navigation.followInternalLink(target)
    }
  )
  private sourceNavigation: OrgFilePreviewNavigation = new OrgFilePreviewNavigation()
  private loadRevision: number = 0
  private needsReload: boolean = false
  private fileVersion: string = ''
  private fileIdentity: string = ''
  @State pageVisible: boolean = true

  aboutToDisappear(): void {
    this.stopFile?.(); this.stopFile = undefined
    this.dataManager?.close().catch((): void => { console.error('关闭项目数据集失败') })
  }
  onPageShow() {
    this.pageVisible = true
    const reload = this.needsReload; this.needsReload = false
    this.loadFile(reload); this.refreshDocument()
  }
  // 页面退出时使进行中的文件读取失效。
  onPageHide() { this.needsReload = this.loading || this.refreshing; this.pageVisible = false; this.loadRevision++; this.filterRequest++; this.filtering = false }
  onBackPress(): boolean {
    if (this.navigation.closePanel()) return true
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    if (this.sourceMode) { this.toggleSource(); return true }
    if (TaskInlineSession.active()) { this.leaveProject(); return true }
    PageNavigator.shared.back(this.getUIContext())
    return true
  }

  async leaveProject() {
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
    if (this.refreshing || !await TaskInlineSession.end(false)) return
    if (!this.sourceMode) await this.rememberReading()
    this.navigation.closePanel()
    this.sourceMode = !this.sourceMode
  }

  async refreshFile() {
    if (this.refreshing || !await TaskInlineSession.end(true)) return
    await this.rememberReading()
    await this.loadFile(true)
  }

  async loadFile(force: boolean = false) {
    if (!this.pageVisible) return
    const params = this.getUIContext().getRouter().getParams() as ProjectParams
    const repoId = params.repoId || '', path = params.path || ''
    if (force || this.message || this.refreshMessage || !this.dataManager || !this.dataManager.hasValidScope() || this.repoId !== repoId || this.path !== path) {
      this.refreshing = true; this.filterRequest++; this.filtering = false
      this.stopFile?.(); this.dataManager?.close().catch((): void => {})
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
        if (event.type === 'error' && !event.targetKey) this.applyFileState({ message: fileDataSet.error })
        else this.refreshDocument()
      })
      const stopMatches = manager.dataSet('matches').subscribe((): void => { this.refreshDocument() })
      const stopMetadata = manager.dataSet('metadata').subscribe((): void => { this.refreshDocument() })
      const stopCategories = manager.dataSet('categories').subscribe((): void => { this.refreshDocument() })
      this.stopFile = (): void => { stopTasks(); stopMatches(); stopMetadata(); stopCategories() }
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
      this.title = projectHeaderTitle(file.category ?? '', file.projectName ?? '')
      this.tagOptions = file.tagOptions.filter(tag => !this.specialTags.includes(tag) && tag !== 'todo')
      this.tagRows = file.tagRows ?? [this.tagOptions]
      this.tagGroups = file.tagGroups
      this.category = file.category ?? ''
      if (this.selectedCategory && this.selectedCategory !== this.category) this.selectedCategory = ''
      this.selectedTags = reconcileTaskTags({ tags: this.selectedTags, includeUntagged: false }, this.tagOptions, this.tagGroups).tags
      if (expression !== this.tagExpression() || selectedCategory !== this.selectedCategory) { this.updateTagQuery(); return }
    }
    const matches = this.dataManager?.dataSet('matches').data
    if (matches?.type === 'task' && !this.filtering && !this.filterMessage) this.matchedIds = matches.result.tasks.map(task => task.id)
    const data = this.fileDataSet?.data
    if (data?.type !== 'task') return
    const sections = reconcileProjectSections(this.sections, data.result.tasks,
      (task: CoreTask): string => this.fileDataSet!.taskKey(task.id))
    if (sections !== this.sections) this.sections = sections
  }

  async saveHeader(changes: CoreFileHeaderValueChange[], version: string): Promise<void> {
    if (!this.fileDataSet || !this.pageVisible) throw new Error('项目页面已离开')
    await this.fileDataSet.updateFileHeader({ repoId: this.repoId, path: this.path }, changes, version)
    this.refreshDocument()
  }

  projectInlineChanged(): void { if (!this.projectInlineActive) this.refreshDocument() }

  async applyFileState(state: ProjectFileState): Promise<void> {
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
      if (!file) throw new Error('项目文件已不存在，请返回存储库列表。')
      if (file.project() === null) {
        await PageNavigator.shared.replacePage(this.getUIContext(), { url: 'pages/FileDetail', params: { repoId, path } })
        return
      }
      const sections = projectReadingSections(file, snapshot.tasks)
      for (const section of sections) if (section.node) section.key = this.fileDataSet!.taskKey(section.node.id)
      const specialTags = file.specialTags()
      const identity = JSON.stringify([repoId, path])
      const changed = identity !== this.fileIdentity || file.fileVersion !== this.fileVersion || this.documentSession !== this.fileDataSet!.identity
      this.title = projectHeaderTitle(file.category() || '', file.project() || '')
      this.sections = sections
      this.headerEntries = file.headerEntries()
      this.headerVersion = file.fileVersion
      this.category = file.category() ?? ''
      this.specialTags = specialTags
      this.content = util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(file.sourceBytes())
      if (changed) {
        if (identity !== this.fileIdentity) this.readingState = ''
        this.fileIdentity = identity
        this.fileVersion = file.fileVersion
        this.documentSession = this.fileDataSet!.identity
        this.renderReady = false
        this.renderRevision++
      }
      this.message = ''
      this.refreshMessage = ''
    } catch (e) {
      if (revision !== this.loadRevision) return
      const message = `读取项目失败：${coreErrorMessage(e as CoreBridgeError)}`
      if (hasSnapshot) this.refreshMessage = `${message}。当前保留上次读取的内容。`
      else this.message = message
    } finally {
      if (revision === this.loadRevision) { this.loading = false; this.refreshing = false; this.refreshDocument() }
    }
  }

  build() {
    Column() {
      AppShell({ title: this.title || '项目', activeRoute: 'pages/ProjectDetail',
        back: PageNavigator.shared.path.depth > 1, drawerOpen: $drawerOpen,
        pullToSync: true, pullDisabled: this.refreshing,
        backAction: (): void => { this.onBackPress() },
        secondaryActionIcon: $r('app.media.ui_document_outline'),
        secondaryActionLabel: this.renderReady && !this.sourceMode && !this.refreshing ? '文档目录' : '',
        secondaryAction: (): void => { this.navigation.openOutline() },
        actionIcon: $r('app.media.ui_more'),
        actionLabel: this.loading || this.message || this.refreshing ? '' : '更多阅读操作',
        actionMenuItems: this.sourceMode ? [
          { title: '返回项目文档', action: (): void => { this.toggleSource() } },
          { title: '刷新项目', action: (): void => { this.refreshFile() } }
        ] : [
          { title: '刷新项目', action: (): void => { this.refreshFile() } },
          { title: '查看原文', action: (): void => { this.toggleSource() } }
        ] }) {
        Column() {
          CoreNotificationsView({ disabled: this.refreshing })
          if (this.loading) {
            EmptyState({ title: '正在打开项目', busy: true })
          } else if (this.message) {
            EmptyState({ title: '无法打开项目', detail: this.message, actionLabel: '重试', action: (): void => { this.loadFile() } })
          } else {
            if (this.refreshing) {
              Row({ space: 8 }) {
                LoadingProgress().width(16).height(16).color(UiColor.primary)
                Text('正在刷新项目').fontSize(12).fontColor(UiColor.secondary)
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
            Stack() {
              ForEach([this.documentSession], (identity: string) => {
              ProjectDocumentView({ dataSet: this.fileDataSet, sections: this.sections, matchedIds: this.matchedIds,
                tagFiltered: this.selectedTags.length > 0 || this.selectedCategory.length > 0,
                headerEntries: this.headerEntries, headerVersion: this.headerVersion, categoryOptions: this.categoryOptions, tagOptions: this.tagOptions,
                beforeHeaderEdit: async (): Promise<boolean> => TaskInlineSession.end(true),
                saveHeader: (changes: CoreFileHeaderValueChange[], version: string): Promise<void> => this.saveHeader(changes, version),
                selectedTags: this.selectedTags, category: this.category, selectedCategory: this.selectedCategory,
                toggleTag: (tag: string): void => { this.selectTag(tag) }, toggleCategory: (): void => { this.selectCategory() }, specialTags: this.specialTags,
                revision: `${this.documentSession}:${this.fileIdentity}:${this.renderRevision}`, navigation: this.navigation,
                internalLinkProcessor: this.internalLinks,
                readingState: this.readingState, showing: this.pageVisible && !this.sourceMode && !this.refreshing,
                scrolled: (offset: number): void => { this.readingState = JSON.stringify({ scroll: offset }) },
                ready: (): void => { this.renderReady = true } })
                .width('100%').height('100%').visibility(this.sourceMode ? Visibility.None : Visibility.Visible)
              }, (identity: string) => identity)
              if (this.sourceMode) {
                OrgFilePreviewView({ content: this.content, displayMode: 'source',
                  title: this.title,
                  revision: `${this.documentSession}:${this.fileIdentity}:${this.renderRevision}`, navigation: this.sourceNavigation })
                  .width('100%').height('100%')
              }
            }.width('100%').layoutWeight(1)
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
