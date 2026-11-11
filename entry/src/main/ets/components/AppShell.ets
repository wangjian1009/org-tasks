import { TaskInlineSession } from '../services/TaskInlineService'
import { CoreTitlePart } from '../services/NativeCoreService'
import { TitleText } from './TitleText'
import { UiColor, UiSize } from '../ui/Theme'
import { IconButton } from './Controls'
import { CompactMenuButton, CompactMenuItem } from './CompactMenuButton'
import { RepositorySyncView } from './RepositorySyncView'
import { uiObserver } from '@kit.ArkUI'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/CoreNotificationService'
import { CoreDataChangeService, CoreDataChangeState, emptyCoreDataChangeState } from '../services/CoreDataChangeService'
import { PageQueryService } from '../services/PageQueryService'
import { AppConfigService } from '../services/AppConfigService'
import { FileTargetService, fileTargetRepository } from '../services/FileTargetService'
import { overviewTaskQuery, overdueTaskQuery, overviewTitle, TaskOverview } from '../services/TaskViewQueries'
import { CoreBridgeError, CoreQuery, NativeCoreService, taskResult, coreErrorMessage } from '../services/NativeCoreService'

export interface AppMenuItem extends CompactMenuItem {}

@Component
export struct AppShell {
  @Prop title: string = ''
  @Prop titleParts: CoreTitlePart[] = []
  @Prop titleIcon: ResourceStr = ''
  @Prop activeRoute: string = ''
  @Prop activeOverview: string = ''
  @Prop back: boolean = false
  @Prop refreshOnPageShow: boolean = false
  @Prop actionIcon: Resource = $r('app.media.ui_more')
  @Prop actionLabel: string = ''
  @Prop actionText: string = ''
  @Prop actionProminent: boolean = false
  @Prop secondaryActionIcon: Resource = $r('app.media.ui_info')
  @Prop secondaryActionLabel: string = ''
  @Prop busy: boolean = false
  @Prop pullToSync: boolean = false
  @Prop pullDisabled: boolean = false
  @Prop actionMenuItems: AppMenuItem[] = []
  @Link @Watch('drawerChanged') drawerOpen: boolean
  @BuilderParam content: () => void
  action: () => void = () => {}
  secondaryAction: () => void = () => {}
  backAction: () => void = (): void => { this.getUIContext().getRouter().back() }
  synchronized: () => void = () => {}
  @State inboxCount: number = -1
  @State todayCount: number = -1
  @State overdueCount: number = 0
  @State plannedCount: number = -1
  @State anytimeCount: number = -1
  @State somedayCount: number = -1
  @State memoCount: number = -1
  @State logbookCount: number = -1
  @State navMessage: string = ''
  @StorageLink('coreNotifications') @Watch('notificationUpdated') notificationState: CoreNotificationsState = emptyCoreNotificationsState()
  @StorageLink('coreDataChanges') @Watch('dataChanged') dataChangeState: CoreDataChangeState = emptyCoreDataChangeState()
  @StorageLink('taskInlineActive') @Watch('inlineSessionChanged') inlineActive: string = ''
  @StorageLink('taskInlineTyping') inlineTyping: boolean = false
  private deferredRefresh: boolean = false
  private pageRefreshDeferred: boolean = false
  private navigationRequest: number = 0
  private navigationLoading: boolean = false
  private navigationRevision: number = -1
  private navigationLoadedOnAppear: boolean = false
  private bodyLoadedOnAppear: boolean = false
  private notificationRevision: number = 0
  private dataRevision: number = 0
  private pageIndex: number = 0
  private pageVisible: boolean = true
  private pageChanged = (info: uiObserver.RouterPageInfo): void => {
    if (info.index !== this.pageIndex) return
    if (info.state === uiObserver.RouterPageState.ON_PAGE_HIDE) {
      this.pageVisible = false
      this.navigationLoadedOnAppear = false
      this.bodyLoadedOnAppear = false
    } else if (info.state === uiObserver.RouterPageState.ON_PAGE_SHOW) {
      this.pageVisible = true
      if (this.refreshOnPageShow) {
        const alreadyLoaded = this.drawerOpen ? this.navigationLoadedOnAppear : this.bodyLoadedOnAppear
        if (alreadyLoaded) this.dataChanged()
        else {
          this.dataRevision = this.dataChangeState.revision
          if (this.drawerOpen) { this.pageRefreshDeferred = true; this.loadNavigation() }
          else this.synchronized()
        }
      } else this.dataChanged()
      this.navigationLoadedOnAppear = false
      this.bodyLoadedOnAppear = false
      this.refreshDataChanges()
    }
  }

  titleLabel(): string {
    return this.titleParts.length > 0 ? this.titleParts.map((part: CoreTitlePart) => part.text).join('') : this.title
  }

  aboutToAppear() {
    this.pageIndex = this.getUIContext().getRouter().getState().index
    this.pageVisible = true
    this.notificationRevision = this.notificationState.revision
    this.dataRevision = this.dataChangeState.revision
    this.getUIContext().getUIObserver().on('routerPageUpdate', this.pageChanged)
    this.refreshDataChanges()
    if (this.drawerOpen) { this.navigationLoadedOnAppear = true; this.loadNavigation() }
    else if (this.refreshOnPageShow) { this.bodyLoadedOnAppear = true; this.synchronized() }
  }

  aboutToDisappear() {
    this.pageVisible = false
    this.getUIContext().getUIObserver().off('routerPageUpdate', this.pageChanged)
  }

  notificationUpdated() {
    if (this.notificationRevision === this.notificationState.revision) return
    this.notificationRevision = this.notificationState.revision
  }

  dataChanged() {
    if (!this.pageVisible || this.dataRevision === this.dataChangeState.revision) return
    this.dataRevision = this.dataChangeState.revision
    this.repositoryDataInvalidated()
  }

  async refreshDataChanges() {
    try { await CoreDataChangeService.refresh(this.getUIContext().getHostContext()!) }
    catch (e) {
      if (!this.pageVisible) return
      console.error(`数据监控注册失败：${coreErrorMessage(e as CoreBridgeError)}`)
    }
  }

  inlineSessionChanged() {
    if (!this.inlineActive && this.deferredRefresh) {
      setTimeout(() => {
        if (this.inlineActive) return
        this.deferredRefresh = false
        this.repositoryDataInvalidated()
      }, 0)
    }
  }

  repositoryDataInvalidated() {
    if (TaskInlineSession.active()) { this.deferredRefresh = true; return }
    if (this.drawerOpen) { this.pageRefreshDeferred = true; this.loadNavigation() }
    else this.synchronized()
  }

  async openDrawer() {
    if (this.back || this.busy) return
    if (TaskInlineSession.active() && !await TaskInlineSession.end(true)) return
    this.drawerOpen = true
  }

  drawerChanged() {
    if (this.drawerOpen) this.loadNavigation()
    else if (this.pageRefreshDeferred) { this.pageRefreshDeferred = false; this.synchronized() }
  }

  async loadNavigation() {
    const revision = this.dataChangeState?.revision ?? 0
    if (this.navigationLoading && this.navigationRevision === revision) return
    this.navigationLoading = true
    this.navigationRevision = revision
    const request = ++this.navigationRequest
    this.navMessage = ''
    this.inboxCount = -1
    try {
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
      const repos = await workspace.repos()
      const queries: CoreQuery[] = [
        { type: 'task', query: overviewTaskQuery('today') }, { type: 'task', query: overdueTaskQuery() },
        { type: 'task', query: overviewTaskQuery('planned') }, { type: 'task', query: overviewTaskQuery('anytime') },
        { type: 'task', query: overviewTaskQuery('logbook') }
      ]
      const prepared = [FileTargetService.prepare(config, repos, 'inbox'), FileTargetService.prepare(config, repos, 'someday'),
        FileTargetService.prepare(config, repos, 'memo')]
      const positions: number[] = []
      for (const target of prepared) {
        positions.push(target ? queries.length : -1)
        if (target) { queries.push(target.task); queries.push(target.file) }
      }
      const results = await PageQueryService.query(config, queries)
      const today = taskResult(results[0])
      const overdue = taskResult(results[1])
      const planned = taskResult(results[2])
      const anytime = taskResult(results[3])
      const logbook = taskResult(results[4])
      const inbox = positions[0] < 0 ? undefined : FileTargetService.result(results[positions[0]], results[positions[0] + 1])
      const someday = positions[1] < 0 ? undefined : FileTargetService.result(results[positions[1]], results[positions[1] + 1])
      const memo = positions[2] < 0 ? undefined : FileTargetService.result(results[positions[2]], results[positions[2] + 1])
      if (request !== this.navigationRequest) return
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
    } finally {
      if (request === this.navigationRequest) this.navigationLoading = false
    }
  }

  async openPrimary(view: TaskOverview | 'inbox') {
    const current = view === 'inbox' ? this.activeRoute === 'pages/Inbox'
      : this.activeRoute === 'pages/TaskOverview' && this.activeOverview === view
    if (!current) this.pageRefreshDeferred = false
    this.drawerOpen = false
    try {
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      if ((view === 'inbox' || view === 'someday' || view === 'memo') && !fileTargetRepository(config, view)) {
        const title = view === 'inbox' ? '收件箱' : overviewTitle(view)
        this.getUIContext().showAlertDialog({ title: `${title}文件未选择或已失效`, message: `请在设置的“笔记与笔记本”中重新选择${title}的仓库和文件。`,
          primaryButton: { value: '取消', action: () => {} }, secondaryButton: { value: '前往设置', action: (): void => {
            this.drawerOpen = false
            this.getUIContext().getRouter().pushUrl({ url: 'pages/Settings', params: { section: '笔记与笔记本' } })
          } } })
        return
      }
      this.drawerOpen = false
      if (view === 'inbox') {
        if (this.activeRoute !== 'pages/Inbox') await this.getUIContext().getRouter().replaceUrl({ url: 'pages/Inbox' })
      } else if (this.activeRoute !== 'pages/TaskOverview' || this.activeOverview !== view) {
        await this.getUIContext().getRouter().replaceUrl({ url: 'pages/TaskOverview', params: { view } })
      }
    } catch (e) { this.navMessage = `读取设置失败：${coreErrorMessage(e as CoreBridgeError)}` }
  }

  async navigate(route: string) {
    if (this.activeRoute !== route) this.pageRefreshDeferred = false
    this.drawerOpen = false
    if (this.activeRoute !== route) {
      try { await this.getUIContext().getRouter().replaceUrl({ url: route }) }
      catch (error) { this.navMessage = '打开页面失败，请重试'; this.drawerOpen = true }
    }
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
          if (this.inlineTyping) {
            Button('完成').height(48).width(64).fontColor(UiColor.primary).backgroundColor(Color.Transparent)
              .onClick(() => { TaskInlineSession.end(false) })
          }
          if (this.secondaryActionLabel.length > 0) {
            IconButton({ icon: this.secondaryActionIcon, label: this.secondaryActionLabel, disabled: this.busy, action: this.secondaryAction })
          }
          if (this.actionLabel.length > 0) {
            if (this.actionText.length > 0) {
              Button(this.actionText).height(this.actionProminent ? 44 : 48).constraintSize({ minWidth: 64 }).fontSize(15)
                .fontColor(this.actionProminent ? Color.White : UiColor.primary)
                .backgroundColor(this.actionProminent ? UiColor.selection : Color.Transparent).borderRadius(22).enabled(!this.busy)
                .accessibilityText(this.actionLabel).onClick((): void => { this.action() })
            } else if (this.actionMenuItems.length > 0) {
              CompactMenuButton({ icon: this.actionIcon, label: this.actionLabel, disabled: this.busy,
                items: this.actionMenuItems })
            } else {
              IconButton({ icon: this.actionIcon, label: this.actionLabel, disabled: this.busy, action: this.action })
            }
          }
        }.width('100%').height(64).padding({ left: 4, right: 4 }).backgroundColor(UiColor.surface)
        if (!this.pullToSync || this.notificationState.notifications.length === 0) {
          Divider().color(UiColor.outline).strokeWidth(0.5)
        }
        Column() {
          RepositorySyncView({ pullEnabled: this.pullToSync, disabled: this.busy || this.drawerOpen || this.pullDisabled,
            beforePull: async (): Promise<boolean> => await TaskInlineSession.end(true) }) {
            this.content()
          }
        }.width('100%').layoutWeight(1)
      }.width('100%').height('100%').backgroundColor(UiColor.surface)
        .onClick(() => { if (TaskInlineSession.active()) TaskInlineSession.end(true) })
      if (this.drawerOpen) {
        Row().width('100%').height('100%').backgroundColor('#66000000').onClick(() => { this.drawerOpen = false })
        this.drawer()
      }
    }.width('100%').height('100%')
  }
}
