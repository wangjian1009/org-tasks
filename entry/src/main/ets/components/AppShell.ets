import { router } from '@kit.ArkUI'
import { UiColor, UiSize } from '../ui/Theme'
import { IconButton } from './Controls'
import { RepositorySyncBanner } from './RepositorySyncBanner'
import { RepositorySyncService, RepositorySyncState, emptyRepositorySyncState } from '../services/RepositorySyncService'
import { AppConfigService } from '../services/AppConfigService'
import { inboxRecordQuery, overviewTaskQuery, overdueTaskQuery, overviewTitle, TaskOverview } from '../services/TaskViewQueries'
import { SavedSearch, SavedSearchService } from '../services/SavedSearchService'
import { CoreBridgeError, CoreConflict, NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'

@Component
export struct AppShell {
  @Prop title: string = ''
  @Prop titleIcon: ResourceStr = ''
  @Prop activeRoute: string = ''
  @Prop activeOverview: string = ''
  @Prop back: boolean = false
  @Prop actionIcon: Resource = $r('app.media.ui_search')
  @Prop actionLabel: string = ''
  @Prop extraIcon: Resource = $r('app.media.ui_more')
  @Prop extraLabel: string = ''
  @Prop fabLabel: string = ''
  @Prop fabIcon: Resource = $r('app.media.ui_add')
  @Prop busy: boolean = false
  @Link @Watch('drawerChanged') drawerOpen: boolean
  @BuilderParam content: () => void
  action: () => void = () => {}
  extraAction: () => void = () => {}
  fabAction: () => void = () => {}
  backAction: () => void = (): void => { router.back() }
  synchronized: () => void = () => {}
  @StorageLink('repositorySync') @Watch('repositorySyncChanged') syncState: RepositorySyncState = emptyRepositorySyncState()
  private syncRevision: number = 0
  private pageIndex: number = 0
  @State inboxCount: number = -1
  @State todayCount: number = -1
  @State overdueCount: number = 0
  @State plannedCount: number = -1
  @State anytimeCount: number = -1
  @State somedayCount: number = -1
  @State memoCount: number = -1
  @State logbookCount: number = -1
  @State searches: SavedSearch[] = []
  @State navMessage: string = ''
  private navigationRequest: number = 0

  aboutToAppear() {
    this.syncRevision = this.syncState.revision
    this.pageIndex = router.getState().index
    this.presentSyncFailure()
    if (this.drawerOpen) this.loadNavigation()
  }

  repositorySyncChanged() {
    if (router.getState().index !== this.pageIndex) return
    this.presentSyncFailure()
    if (this.syncRevision === this.syncState.revision) return
    this.syncRevision = this.syncState.revision
    this.synchronized()
    if (this.drawerOpen) this.loadNavigation()
  }

  presentSyncFailure() {
    if (router.getState().index !== this.pageIndex) return
    const failure = RepositorySyncService.takeFailure()
    if (!failure) return
    this.getUIContext().showAlertDialog({ title: '同步失败', message: failure.message,
      primaryButton: { value: '关闭', action: () => {} },
      secondaryButton: {
        value: failure.conflicts.length > 0 ? '处理冲突' : failure.needsRepository ? '添加存储库' : '重试',
        action: (): void => {
          if (failure.conflicts.length > 0) {
            this.getUIContext().showActionSheet({ title: '同步冲突', message: '选择需要处理的同步作业',
              sheets: failure.conflicts.map((conflict: CoreConflict): SheetInfo => ({
                title: `${conflict.paths.length} 个文件：${conflict.paths.join('、')}`,
                action: (): void => { router.pushUrl({ url: 'pages/MergeConflict', params: { repoId: conflict.repoId, syncId: conflict.syncId } }) }
              })) })
          } else if (failure.needsRepository) {
            router.pushUrl({ url: 'pages/Files' })
          } else {
            RepositorySyncService.start(getContext(this))
          }
        }
      } })
  }

  openDrawer() {
    this.drawerOpen = true
  }

  drawerChanged() {
    if (this.drawerOpen) this.loadNavigation()
  }

  async loadNavigation() {
    const request = ++this.navigationRequest
    this.navMessage = ''
    this.inboxCount = -1
    try {
      const config = await AppConfigService.load(getContext(this))
      const searches = await SavedSearchService.load(getContext(this))
      const inbox = config.inboxFile ? await NativeCoreService.queryTasks(config.repos, inboxRecordQuery(config.inboxFile), config.todoDefaults) : undefined
      const today = await NativeCoreService.queryTasks(config.repos, overviewTaskQuery('today'), config.todoDefaults)
      const overdue = await NativeCoreService.queryTasks(config.repos, overdueTaskQuery(), config.todoDefaults)
      const planned = await NativeCoreService.queryTasks(config.repos, overviewTaskQuery('planned'), config.todoDefaults)
      const anytime = await NativeCoreService.queryTasks(config.repos, overviewTaskQuery('anytime'), config.todoDefaults)
      const someday = config.somedayFile ? await NativeCoreService.queryTasks(config.repos, overviewTaskQuery('someday', config.somedayFile), config.todoDefaults) : undefined
      const memo = config.memoFile ? await NativeCoreService.queryTasks(config.repos, overviewTaskQuery('memo', '', config.memoFile), config.todoDefaults) : undefined
      const logbook = await NativeCoreService.queryTasks(config.repos, overviewTaskQuery('logbook'), config.todoDefaults)
      if (request !== this.navigationRequest) return
      this.searches = searches
      this.inboxCount = inbox?.tasks.length ?? -1
      this.todayCount = today.tasks.length
      this.overdueCount = overdue.tasks.length
      this.plannedCount = planned.tasks.length
      this.anytimeCount = anytime.tasks.length
      this.somedayCount = someday?.tasks.length ?? -1
      this.memoCount = memo?.tasks.length ?? -1
      this.logbookCount = logbook.tasks.length
    } catch (e) {
      if (request === this.navigationRequest) this.navMessage = `读取导航失败：${coreErrorMessage(e as CoreBridgeError)}`
    }
  }

  async openPrimary(view: TaskOverview | 'inbox') {
    this.drawerOpen = false
    try {
      const config = await AppConfigService.load(getContext(this))
      if (view === 'inbox' && !config.inboxFile || view === 'someday' && !config.somedayFile || view === 'memo' && !config.memoFile) {
        const title = view === 'inbox' ? '收件箱' : overviewTitle(view)
        this.getUIContext().showAlertDialog({ title: `尚未配置${title}`, message: `请在设置的“笔记与笔记本”中配置${title}文件。`,
          primaryButton: { value: '取消', action: () => {} }, secondaryButton: { value: '前往设置', action: (): void => {
            this.drawerOpen = false
            router.pushUrl({ url: 'pages/Settings', params: { section: '笔记与笔记本' } })
          } } })
        return
      }
      this.drawerOpen = false
      if (view === 'inbox') {
        if (this.activeRoute !== 'pages/Inbox') router.replaceUrl({ url: 'pages/Inbox' })
      } else if (this.activeRoute !== 'pages/TaskOverview' || this.activeOverview !== view) {
        router.replaceUrl({ url: 'pages/TaskOverview', params: { view } })
      }
    } catch (e) { this.navMessage = `读取设置失败：${coreErrorMessage(e as CoreBridgeError)}` }
  }

  navigate(route: string) {
    this.drawerOpen = false
    if (this.activeRoute !== route) {
      router.replaceUrl({ url: route })
    }
  }

  openSearch(search: SavedSearch) {
    this.drawerOpen = false
    router.replaceUrl({ url: 'pages/Search', params: { query: search.query, name: search.name, run: true } })
  }

  primaryCount(view: TaskOverview | 'inbox'): number {
    switch (view) {
      case 'inbox': return this.inboxCount
      case 'today': return this.todayCount
      case 'planned': return this.plannedCount
      case 'anytime': return this.anytimeCount
      case 'someday': return this.somedayCount
      case 'memo': return this.memoCount
      case 'logbook': return this.logbookCount
    }
  }

  @Builder
  primaryItem(title: string, icon: Resource, view: TaskOverview | 'inbox') {
    Row({ space: 12 }) {
      Image(icon).width(UiSize.drawerIcon).height(UiSize.drawerIcon)
      Text(title).fontSize(UiSize.drawerFont).fontWeight(FontWeight.Medium).fontColor(UiColor.drawerText).layoutWeight(1)
      if (view === 'today' && this.overdueCount > 0) {
        Text(`${this.overdueCount}`).fontSize(UiSize.drawerFont).fontWeight(FontWeight.Bold).fontColor(Color.White)
          .padding({ left: 8, right: 8 }).height(24).constraintSize({ minWidth: 26 })
          .textAlign(TextAlign.Center).borderRadius(12).backgroundColor(UiColor.overdueBadge)
      }
      if (this.primaryCount(view) >= 0) {
        Text(`${this.primaryCount(view)}`).fontSize(UiSize.drawerFont).fontWeight(FontWeight.Medium).fontColor(UiColor.drawerSecondary)
      }
    }.width('100%').height(UiSize.drawerRow).padding({ left: 12, right: 12 }).borderRadius(12)
      .backgroundColor(view === 'inbox' ? (this.activeRoute === 'pages/Inbox' ? UiColor.drawerSelected : Color.Transparent)
        : this.activeRoute === 'pages/TaskOverview' && this.activeOverview === view ? UiColor.drawerSelected : Color.Transparent)
      .accessibilityText(`${title}${this.primaryCount(view) >= 0 ? `，${this.primaryCount(view)} 条` : ''}${view === 'today' && this.overdueCount > 0 ? `，过期 ${this.overdueCount} 个` : ''}`)
      .onClick((): void => { this.openPrimary(view) })
  }

  @Builder
  navItem(title: string, icon: Resource, route: string, selected: boolean = false, count: number = -1) {
    Row({ space: 12 }) {
      Image(icon).width(UiSize.drawerIcon).height(UiSize.drawerIcon)
      Text(title).fontSize(UiSize.drawerFont).fontColor(UiColor.drawerText).fontWeight(selected ? FontWeight.Medium : FontWeight.Normal)
        .layoutWeight(1)
      if (count >= 0) {
        Text(`${count}`).fontSize(UiSize.drawerFont).fontColor(UiColor.drawerSecondary)
      }
    }.width('100%').height(UiSize.drawerRow).padding({ left: 16, right: 16 }).borderRadius(12)
      .backgroundColor(selected ? UiColor.drawerSelected : Color.Transparent)
      .onClick((): void => { this.navigate(route) })
  }

  @Builder
  drawer() {
    Column() {
      Scroll() {
        Column({ space: 2 }) {
          this.primaryItem('收件箱', $r('app.media.nav_inbox'), 'inbox')
          Row().height(6)
          this.primaryItem('今天', $r('app.media.nav_today'), 'today')
          this.primaryItem('计划', $r('app.media.nav_planned'), 'planned')
          this.primaryItem('随时', $r('app.media.nav_anytime'), 'anytime')
          this.primaryItem('某天', $r('app.media.nav_someday'), 'someday')
          this.primaryItem('备忘', $r('app.media.nav_memo'), 'memo')
          Row().height(12)
          this.primaryItem('日志簿', $r('app.media.nav_logbook'), 'logbook')
          ForEach(this.searches, (search: SavedSearch) => {
            Text(search.name).fontSize(UiSize.drawerFont).fontColor(UiColor.drawerSecondary).width('100%').padding({ left: 58, right: 16, top: 8, bottom: 8 })
              .onClick((): void => { this.openSearch(search) })
          }, (search: SavedSearch) => search.id)
          Divider().color(UiColor.drawerOutline).margin({ top: 4, bottom: 4 })
          this.navItem('存储库', $r('app.media.nav_repository'), 'pages/Files', this.activeRoute === 'pages/Files')
          if (this.navMessage.length > 0) {
            Text(this.navMessage).fontSize(UiSize.drawerFont).fontColor(UiColor.error).padding(16)
          }
        }.width('100%').padding({ left: 12, right: 12, bottom: 16 })
      }.layoutWeight(1).width('100%').padding({ top: 16 }).align(Alignment.TopStart)
      Divider().color(UiColor.drawerOutline)
      this.navItem('设置', $r('app.media.nav_settings'), 'pages/Settings', this.activeRoute === 'pages/Settings')
    }.width('84%').constraintSize({ maxWidth: 340 }).height('100%').backgroundColor(UiColor.drawer)
      .borderRadius({ topRight: 20, bottomRight: 20 })
      .onClick((): void => { this.drawerOpen = false })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Row() {
          if (this.back) {
            IconButton({ icon: $r('app.media.ui_back'), label: '返回', disabled: this.busy,
              action: () => { this.backAction() } })
          }
          Row({ space: 8 }) {
            if (this.titleIcon !== '') {
              Image(this.titleIcon).width(26).height(26).enabled(!this.busy)
                .accessibilityText(`打开导航，${this.title}`).onClick((): void => { this.openDrawer() })
            }
            Text(this.title).fontSize(22).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
              .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .accessibilityText(`打开导航，${this.title}`).enabled(!this.busy)
              .onClick((): void => { this.openDrawer() })
          }.layoutWeight(1).height(48).padding({ left: 8, right: 8 }).borderRadius(12)
          if (this.actionLabel.length > 0) {
            IconButton({ icon: this.actionIcon, label: this.actionLabel, disabled: this.busy, action: this.action })
          }
          if (this.extraLabel.length > 0) {
            IconButton({ icon: this.extraIcon, label: this.extraLabel, disabled: this.busy, action: this.extraAction })
          }
        }.width('100%').height(64).padding({ left: 4, right: 4 }).backgroundColor(UiColor.surface)
        Divider().color(UiColor.outline).strokeWidth(0.5)
        RepositorySyncBanner()
        Stack({ alignContent: Alignment.BottomEnd }) {
          this.content()
          if (this.fabLabel.length > 0) {
            Button({ type: ButtonType.Normal }) {
              Image(this.fabIcon).width(26).height(26)
            }.width(56).height(56).borderRadius(16).backgroundColor(UiColor.selected)
              .shadow({ radius: 6, color: '#22000000', offsetY: 2 })
              .margin({ right: 16, bottom: 20 }).accessibilityText(this.fabLabel)
              .enabled(!this.busy).onClick((): void => { this.fabAction() })
          }
        }.width('100%').layoutWeight(1)
      }.width('100%').height('100%').backgroundColor(UiColor.surface)
      if (this.drawerOpen) {
        Row().width('100%').height('100%').backgroundColor('#66000000').onClick(() => { this.drawerOpen = false })
        this.drawer()
      }
    }.width('100%').height('100%')
  }
}
