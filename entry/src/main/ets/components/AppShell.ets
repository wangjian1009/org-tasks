import { CoreTitlePart } from '../services/NativeCoreService'
import { TitleText } from './TitleText'
import { router } from '@kit.ArkUI'
import { UiColor, UiSize } from '../ui/Theme'
import { IconButton } from './Controls'
import { RepositorySyncView } from './RepositorySyncView'
import { AppConfigService } from '../services/AppConfigService'
import { inboxRecordQuery, overviewTaskQuery, overdueTaskQuery, overviewTitle, TaskOverview } from '../services/TaskViewQueries'
import { SavedSearch, SavedSearchService } from '../services/SavedSearchService'
import { CoreBridgeError, NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'

@Component
export struct AppShell {
  @Prop title: string = ''
  @Prop titleParts: CoreTitlePart[] = []
  @Prop titleIcon: ResourceStr = ''
  @Prop activeRoute: string = ''
  @Prop activeOverview: string = ''
  @Prop back: boolean = false
  @Prop actionIcon: Resource = $r('app.media.ui_search')
  @Prop actionLabel: string = ''
  @Prop busy: boolean = false
  @Prop pullToSync: boolean = false
  @Link @Watch('drawerChanged') drawerOpen: boolean
  @BuilderParam content: () => void
  action: () => void = () => {}
  backAction: () => void = (): void => { router.back() }
  synchronized: () => void = () => {}
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

  titleLabel(): string {
    return this.titleParts.length > 0 ? this.titleParts.map((part: CoreTitlePart) => part.text).join('') : this.title
  }

  aboutToAppear() {
    if (this.drawerOpen) this.loadNavigation()
  }

  repositoryDataInvalidated() {
    this.synchronized()
    if (this.drawerOpen) this.loadNavigation()
  }

  openDrawer() {
    if (this.back || this.busy) return
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
                .accessibilityText(this.back ? this.titleLabel() : `打开导航，${this.titleLabel()}`)
                .onClick((): void => { this.openDrawer() })
            }
            TitleText({ text: this.title, parts: this.titleParts, textSize: 22, weight: FontWeight.Medium, lineLimit: 1 }).flexShrink(1)
              .accessibilityText(this.back ? this.titleLabel() : `打开导航，${this.titleLabel()}`).enabled(!this.busy)
              .onClick((): void => { this.openDrawer() })
          }.layoutWeight(1).height(48).padding({ left: 8, right: 8 }).borderRadius(12)
          if (this.actionLabel.length > 0) {
            IconButton({ icon: this.actionIcon, label: this.actionLabel, disabled: this.busy, action: this.action })
          }
        }.width('100%').height(64).padding({ left: 4, right: 4 }).backgroundColor(UiColor.surface)
        Divider().color(UiColor.outline).strokeWidth(0.5)
        Column() {
          RepositorySyncView({ pullEnabled: this.pullToSync, disabled: this.busy || this.drawerOpen,
            onDataInvalidated: (): void => { this.repositoryDataInvalidated() } }) {
            this.content()
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
