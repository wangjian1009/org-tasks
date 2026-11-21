import { PageNavigator, primaryPage } from '../services/PageNavigator'
import { LinkEditController } from './LinkView'
import { TaskInlineSession } from '../services/TaskInlineService'
import { CoreTitlePart } from '../services/NativeCoreService'
import { TitleText } from './TitleText'
import { UiColor, UiSize } from '../ui/Theme'
import { IconButton } from './controls/IconButton'
import { ProjectProgressIcon } from './ProjectProgressIcon'
import { PopupMenuButton } from './controls/PopupMenuButton'
import { PopupMenuItem } from './controls/PopupMenu'
import { RepositorySyncView } from './RepositorySyncView'
import { NotificationManager } from '../services/NotificationManager'
import { SidebarDataManager, SidebarSnapshot } from '../services/SidebarDataManager'
import { ProjectNavigation } from '../services/ProjectNavigation'
import { fileTaskProgress, fileTaskCount, fileCompletedTaskCount, projectSections, ProjectSection } from '../ui/NotebookPresentation'
import { overviewTitle, TaskView } from '../services/TaskViewQueries'
import { CoreBridgeError, CoreOrgFileMetadata, coreErrorMessage } from '../services/NativeCoreService'
import { RegionOrderService } from '../services/RegionOrderService'
import { RegionOrder } from '../ui/RegionOrderPresentation'

@Component
export struct AppShell {
  @Prop title: string = ''
  @Prop titleContext: string = ''
  @Prop titleParts: CoreTitlePart[] = []
  @Prop titleIcon: ResourceStr = ''
  @Prop activeRoute: string = ''
  @Prop activeOverview: string = ''
  @Prop back: boolean = false
  @Prop actionIcon: Resource = $r('app.media.ui_more')
  @Prop actionLabel: string = ''
  @Prop actionText: string = ''
  @Prop actionProminent: boolean = false
  @Prop secondaryActionIcon: Resource = $r('app.media.ui_info')
  @Prop secondaryActionLabel: string = ''
  @Prop busy: boolean = false
  @Prop pullToSync: boolean = false
  @Prop pullDisabled: boolean = false
  @Prop actionMenuItems: PopupMenuItem[] = []
  @Link @Watch('drawerChanged') drawerOpen: boolean
  @BuilderParam content: () => void
  action: () => void = () => {}
  secondaryAction: () => void = () => {}
  backAction: () => void = (): void => { PageNavigator.shared.back(this.getUIContext()) }
  @State inboxCount: number = -1
  @State todayCount: number = -1
  @State todayAttentionCount: number = 0
  @State plannedCount: number = -1
  @State waitingCount: number = -1
  @State anytimeCount: number = -1
  @State somedayCount: number = -1
  @State memoCount: number = -1
  @State logbookCount: number = -1
  @State trashCount: number = -1
  @State regionOrder: RegionOrder | null = null
  @State projects: CoreOrgFileMetadata[] = []
  @State projectGroups: ProjectSection[] = []
  @State navMessage: string = ''
  @State showNotifications: boolean = false
  private stopNotifications: (() => void) | undefined = undefined
  @StorageLink('taskInlineTyping') inlineTyping: boolean = false
  private sidebarManager: SidebarDataManager | undefined = undefined
  private stopSidebar: (() => void) | undefined = undefined
  private orderChanged: ((order: RegionOrder | null) => void) | undefined = undefined
  private orderRevision: number = 0

  titleLabel(): string {
    return this.titleParts.length > 0 ? this.titleParts.map((part: CoreTitlePart) => part.text).join('') : this.title
  }

  aboutToAppear() {
    this.stopNotifications = NotificationManager.watchVisibility(visible => { this.showNotifications = visible })
    if (this.drawerOpen) this.loadNavigation()
  }

  aboutToDisappear() {
    this.stopNotifications?.()
    this.stopNotifications = undefined
    this.stopSidebar?.(); this.stopSidebar = undefined
    this.sidebarManager?.close(); this.sidebarManager = undefined
    if (this.orderChanged) RegionOrderService.stopWatchingChanges(this.orderChanged)
    this.orderChanged = undefined
    this.orderRevision++
  }

  async openDrawer() {
    if (this.back || this.busy) return
    if (TaskInlineSession.active() && !await TaskInlineSession.end(true)) return
    this.drawerOpen = true
  }

  drawerChanged() {
    if (this.drawerOpen) this.loadNavigation()
  }

  navigationDataManager(): SidebarDataManager {
    if (!this.sidebarManager) {
      this.orderChanged = (order: RegionOrder | null): void => {
        this.orderRevision = (this.orderRevision ?? 0) + 1
        this.regionOrder = order
        this.projectGroups = projectSections(this.projects, order)
      }
      RegionOrderService.watchChanges(this.orderChanged)
      this.sidebarManager = new SidebarDataManager(this.getUIContext().getHostContext()!)
      this.stopSidebar = this.sidebarManager.subscribe((snapshot: SidebarSnapshot): void => {
        this.inboxCount = snapshot.inboxCount
        this.todayCount = snapshot.todayCount
        this.todayAttentionCount = snapshot.todayAttentionCount
        this.plannedCount = snapshot.plannedCount
        this.waitingCount = snapshot.waitingCount
        this.anytimeCount = snapshot.anytimeCount
        this.somedayCount = snapshot.somedayCount
        this.memoCount = snapshot.memoCount
        this.logbookCount = snapshot.logbookCount
        this.trashCount = snapshot.trashCount
        this.projects = snapshot.projects
        this.projectGroups = projectSections(snapshot.projects, this.regionOrder)
        this.navMessage = snapshot.message
      })
    }
    return this.sidebarManager
  }

  async loadNavigation() {
    const manager = this.navigationDataManager()
    const request = this.orderRevision = (this.orderRevision ?? 0) + 1
    let orderError = ''
    await Promise.all([manager.start(), RegionOrderService.load(this.getUIContext().getHostContext()!).then((order: RegionOrder | null): void => {
      if (request !== this.orderRevision) return
      this.regionOrder = order
      this.projectGroups = projectSections(this.projects, order)
    }).catch((error: Error): void => { orderError = error.message })])
    if (orderError && request === this.orderRevision) this.navMessage = orderError
  }

  async openPrimary(view: TaskView | 'inbox') {
    this.drawerOpen = false
    try {
      if ((view === 'inbox' || view === 'someday' || view === 'memo') && !await this.navigationDataManager().targetConfigured(view)) {
        const title = view === 'inbox' ? '收件箱' : overviewTitle(view)
        this.getUIContext().showAlertDialog({ title: `${title}文件未选择或已失效`, message: `请在设置的“文件入口”中重新选择${title}的仓库和文件。`,
          primaryButton: { value: '取消', action: () => {} }, secondaryButton: { value: '前往设置', action: (): void => {
            this.drawerOpen = false
            PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/Settings', params: { section: '文件入口' } })
          } } })
        return
      }
      this.drawerOpen = false
      await PageNavigator.shared.openPrimary(this.getUIContext(), primaryPage(view))
    } catch (e) { this.navMessage = `读取设置失败：${coreErrorMessage(e as CoreBridgeError)}` }
  }

  async navigate(route: string) {
    this.drawerOpen = false
    if (!await PageNavigator.shared.openPrimary(this.getUIContext(), { url: route })) {
      this.navMessage = '打开页面失败，请重试'; this.drawerOpen = true
    }
  }

  async openProject(file: CoreOrgFileMetadata) {
    if (await ProjectNavigation.open(this.getUIContext(), file.repoId, file.path, true)) {
      this.drawerOpen = false
    }
  }


  primaryCount(view: TaskView | 'inbox'): number {
    switch (view) {
      case 'inbox': return this.inboxCount
      case 'today': return this.todayCount
      case 'planned': return this.plannedCount
      case 'waiting': return this.waitingCount
      case 'anytime': return this.anytimeCount
      case 'someday': return this.somedayCount
      case 'memo': return this.memoCount
      case 'logbook': return this.logbookCount
    }
  }

  @Builder
  primaryItem(title: string, icon: Resource, view: TaskView | 'inbox') {
    Row({ space: 12 }) {
      Image(icon).width(UiSize.drawerIcon).height(UiSize.drawerIcon)
      Text(title).fontSize(UiSize.drawerFont).fontWeight(FontWeight.Medium).fontColor(UiColor.drawerText).layoutWeight(1)
      if (view === 'today' && this.todayAttentionCount > 0) {
        Text(`${this.todayAttentionCount}`).fontSize(UiSize.drawerFont).fontWeight(FontWeight.Bold).fontColor(Color.White)
          .padding({ left: 8, right: 8 }).height(24).constraintSize({ minWidth: 26 })
          .textAlign(TextAlign.Center).borderRadius(12).backgroundColor(UiColor.overdueBadge)
      }
      if (this.primaryCount(view) >= 0) {
        Text(`${this.primaryCount(view)}`).fontSize(UiSize.drawerFont).fontWeight(FontWeight.Medium).fontColor(UiColor.drawerSecondary)
      }
    }.width('100%').height(UiSize.drawerRow).padding({ left: 12, right: 12 }).borderRadius(12)
      .backgroundColor(view === 'inbox' ? (this.activeRoute === 'pages/Inbox' ? UiColor.drawerSelected : Color.Transparent)
        : this.activeRoute === primaryPage(view).url ? UiColor.drawerSelected : Color.Transparent)
      .accessibilityText(`${title}${this.primaryCount(view) >= 0 ? `，${this.primaryCount(view)} 条` : ''}${view === 'today' && this.todayAttentionCount > 0 ? `，需处理 ${this.todayAttentionCount} 个` : ''}`)
      .onClick((): void => { this.openPrimary(view) })
  }

  @Builder
  projectItem(file: CoreOrgFileMetadata) {
    Row({ space: 12 }) {
      ProjectProgressIcon({ completed: fileCompletedTaskCount(file), total: fileTaskCount(file) }).flexShrink(0)
      Text(file.project() || '未命名项目').fontSize(UiSize.drawerFont).fontWeight(FontWeight.Medium)
        .fontColor(UiColor.drawerText).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%').height(UiSize.drawerRow).padding({ left: 12, right: 12 }).borderRadius(12)
      .accessibilityGroup(true).accessibilityText(`${file.project() || '未命名项目'}，已完成/总任务数 ${fileTaskProgress(file)}`)
      .onClick((): void => { this.openProject(file) })
  }

  @Builder
  projectSection(section: ProjectSection) {
    Column() {
      Row({ space: 12 }) {
        Image($r('app.media.nav_project_category')).width(UiSize.drawerIcon).height(UiSize.drawerIcon)
          .accessibilityLevel('no')
        Text(section.category || '未分类').fontSize(UiSize.drawerFont).fontWeight(FontWeight.Medium)
          .fontColor(UiColor.drawerText).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%').height(40).padding({ left: 12, right: 12 }).margin({ bottom: 4 })
        .accessibilityText(`项目分类，${section.category || '未分类'}`)
      ForEach(section.files, (file: CoreOrgFileMetadata) => {
        this.projectItem(file)
      }, (file: CoreOrgFileMetadata) => JSON.stringify([file.repoId, file.path, file.project(), file.taskStateCounts]))
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  navItem(title: string, icon: Resource, route: string, selected: boolean = false) {
    Row({ space: 12 }) {
      Image(icon).width(UiSize.drawerIcon).height(UiSize.drawerIcon)
      Text(title).fontSize(UiSize.drawerFont).fontColor(UiColor.drawerText).fontWeight(selected ? FontWeight.Medium : FontWeight.Normal)
        .layoutWeight(1)
      if (this.navigationCount(route) >= 0) {
        Text(`${this.navigationCount(route)}`).fontSize(UiSize.drawerFont).fontColor(UiColor.drawerSecondary)
      }
    }.width('100%').height(UiSize.drawerRow).padding({ left: 16, right: 16 }).borderRadius(12)
      .backgroundColor(selected ? UiColor.drawerSelected : Color.Transparent)
      .accessibilityText(`${title}${this.navigationCount(route) >= 0 ? `，${this.navigationCount(route)} 条` : ''}`)
      .onClick((): void => { this.navigate(route) })
  }

  navigationCount(route: string): number { return route === 'pages/Trash' ? this.trashCount : -1 }

  @Builder
  drawer() {
    Column() {
      Scroll() {
        Column({ space: 2 }) {
          this.primaryItem('收件箱', $r('app.media.nav_inbox'), 'inbox')
          Row().height(6)
          this.primaryItem('今天', $r('app.media.nav_today'), 'today')
          this.primaryItem('计划', $r('app.media.nav_planned'), 'planned')
          this.primaryItem('等待', $r('app.media.nav_waiting'), 'waiting')
          this.primaryItem('随时', $r('app.media.nav_anytime'), 'anytime')
          this.primaryItem('某天', $r('app.media.nav_someday'), 'someday')
          this.primaryItem('备忘', $r('app.media.nav_memo'), 'memo')
          Row().height(12)
          this.primaryItem('日志簿', $r('app.media.nav_logbook'), 'logbook')
          this.navItem('废纸篓', $r('app.media.ui_delete'), 'pages/Trash', this.activeRoute === 'pages/Trash')
          Divider().color(UiColor.drawerOutline).margin({ top: 4, bottom: 4 })
          if (this.projectGroups.length > 0) {
            Column({ space: 32 }) {
              ForEach(this.projectGroups, (section: ProjectSection) => {
                this.projectSection(section)
              }, (section: ProjectSection) => JSON.stringify(section))
            }.width('100%').padding({ top: 8, bottom: 8 })
            Divider().color(UiColor.drawerOutline).margin({ top: 4, bottom: 4 })
          }
          this.navItem('笔记本', $r('app.media.nav_repository'), 'pages/Files', this.activeRoute === 'pages/Files')
          if (this.navMessage.length > 0) {
            Text(this.navMessage).fontSize(UiSize.drawerFont).fontColor(UiColor.error).padding(16)
          }
        }.width('100%').padding({ left: 12, right: 12, bottom: 16 })
      }.layoutWeight(1).width('100%').padding({ top: 16 }).align(Alignment.TopStart).scrollBar(BarState.Off)
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
            TitleText({ text: this.title, parts: this.titleParts, textSize: 22, weight: FontWeight.Medium, lineLimit: 1,
              openLinks: this.back, activate: (): void => { this.openDrawer() } }).flexShrink(1)
              .accessibilityText(this.back ? this.titleLabel() : `打开导航，${this.titleLabel()}`).enabled(!this.busy)
            if (this.titleContext) {
              Text(this.titleContext).fontSize(11).fontColor(UiColor.secondary).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(2)
            }
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
              PopupMenuButton({ icon: this.actionIcon, label: this.actionLabel, disabled: this.busy,
                items: this.actionMenuItems })
            } else {
              IconButton({ icon: this.actionIcon, label: this.actionLabel, disabled: this.busy, action: this.action })
            }
          }
        }.width('100%').height(64).padding({ left: 4, right: 4 }).backgroundColor(UiColor.surface)
        if (!this.pullToSync || !this.showNotifications) {
          Divider().color(UiColor.outline).strokeWidth(0.5)
        }
        Column() {
          RepositorySyncView({ pullEnabled: this.pullToSync, disabled: this.busy || this.drawerOpen || this.pullDisabled,
            beforePull: async (): Promise<boolean> => await TaskInlineSession.end(true) }) {
            this.content()
          }
        }.width('100%').layoutWeight(1)
      }.width('100%').height('100%').backgroundColor(UiColor.surface)
        .onClick(() => { if (TaskInlineSession.active() && !LinkEditController.interactionProtected()) TaskInlineSession.end(true) })
      if (this.drawerOpen) {
        Row().width('100%').height('100%').backgroundColor('#66000000').onClick(() => { this.drawerOpen = false })
        this.drawer()
      }
    }.width('100%').height('100%')
  }
}
