import { router } from '@kit.ArkUI'
import { UiColor } from '../ui/Theme'
import { IconButton } from './Controls'
import { AppConfigService } from '../services/AppConfigService'
import { categoryNavigationQuery, inboxRecordQuery } from '../services/TaskViewQueries'
import { BUILTIN_SEARCHES, SavedSearch, SavedSearchService } from '../services/SavedSearchService'
import { CoreBridgeError, CoreTaskCategory, NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'

@Component
export struct AppShell {
  @Prop title: string = ''
  @Prop activeRoute: string = ''
  @Prop activeCategoryValues: (string | null)[] = []
  @Prop activeCategories: CoreTaskCategory[] = []
  @Prop categoryBusy: boolean = false
  categoryToggled: (category: string | null) => void = () => {}
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
  @State categories: CoreTaskCategory[] = []
  @State inboxCount: number = 0
  @State searches: SavedSearch[] = []
  @State navMessage: string = ''
  private navigationRequest: number = 0

  aboutToAppear() {
    if (this.drawerOpen) this.loadNavigation()
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
    this.categories = []
    this.inboxCount = 0
    try {
      const config = await AppConfigService.load(getContext(this))
      const searches = await SavedSearchService.load(getContext(this))
      const result = await NativeCoreService.queryTasks(config.repos, categoryNavigationQuery(config.inboxFile), config.todoDefaults)
      const inbox = await NativeCoreService.queryTasks(config.repos, inboxRecordQuery(config.inboxFile), config.todoDefaults)
      if (request !== this.navigationRequest) return
      this.searches = searches
      this.categories = result.categories
      this.inboxCount = inbox.tasks.length
    } catch (e) {
      if (request === this.navigationRequest) this.navMessage = `读取导航失败：${coreErrorMessage(e as CoreBridgeError)}`
    }
  }

  navigate(route: string) {
    this.drawerOpen = false
    if (this.activeRoute !== route) {
      router.replaceUrl({ url: route })
    }
  }

  navigationCategories(): CoreTaskCategory[] {
    return this.activeRoute === 'pages/CategoryTasks' ? this.activeCategories : this.categories
  }

  toggleCategory(category: CoreTaskCategory) {
    if (this.activeRoute === 'pages/CategoryTasks') {
      this.categoryToggled(category.category)
    } else {
      router.replaceUrl({ url: 'pages/CategoryTasks', params: { categories: [category.category], drawerOpen: true } })
    }
  }

  openSearch(search: SavedSearch) {
    this.drawerOpen = false
    router.replaceUrl({ url: 'pages/Search', params: { query: search.query, name: search.name, run: true } })
  }

  @Builder
  navItem(title: string, icon: Resource, route: string, selected: boolean = false, count: number = -1) {
    Row({ space: 20 }) {
      Image(icon).width(22).height(22)
      Text(title).fontSize(15).fontColor(UiColor.text).fontWeight(selected ? FontWeight.Medium : FontWeight.Normal)
        .layoutWeight(1)
      if (count >= 0) {
        Text(`${count}`).fontSize(12).fontColor(UiColor.secondary)
      }
    }.width('100%').height(52).padding({ left: 16, right: 16 }).borderRadius(26)
      .backgroundColor(selected ? UiColor.selected : Color.Transparent)
      .onClick((): void => { this.navigate(route) })
  }

  @Builder
  drawer() {
    Column() {
      Row() {
        Row({ space: 20 }) {
          Image($r('app.media.ui_search')).width(22).height(22)
          Text('搜索').fontSize(18).fontColor(UiColor.text)
        }.layoutWeight(1).height(48).borderRadius(24).accessibilityText('搜索任务')
          .onClick((): void => {
            this.drawerOpen = false
            router.replaceUrl({ url: 'pages/Search' })
          })
        IconButton({ icon: $r('app.media.ui_close'), label: '关闭导航', action: () => { this.drawerOpen = false } })
      }.width('100%').padding({ left: 20, right: 8, top: 8, bottom: 8 })
      Scroll() {
        Column({ space: 2 }) {
          this.navItem('收件箱', $r('app.media.ui_body'), 'pages/Inbox', this.activeRoute === 'pages/Inbox', this.inboxCount)
          this.navItem('日程', $r('app.media.ui_calendar'), 'pages/Agenda', this.activeRoute === 'pages/Agenda')
          ForEach(BUILTIN_SEARCHES.concat(this.searches), (search: SavedSearch) => {
            Text(search.name).fontSize(14).fontColor(UiColor.secondary).width('100%').padding({ left: 58, right: 16, top: 15, bottom: 15 })
              .onClick((): void => { this.openSearch(search) })
          }, (search: SavedSearch) => search.id)
          Divider().color(UiColor.outline).margin({ top: 8, bottom: 8 })
          Text('分类').fontSize(12).fontColor(UiColor.primary).width('100%').padding({ left: 16, top: 8, bottom: 8 })
          ForEach(this.navigationCategories(), (category: CoreTaskCategory) => {
            Row({ space: 12 }) {
              Text(this.activeCategoryValues.includes(category.category) ? '✓' : '').fontSize(14).fontColor(UiColor.primary)
                .width(20).height(20).textAlign(TextAlign.Center).borderRadius(3)
                .border({ width: 1, color: this.activeCategoryValues.includes(category.category) ? UiColor.primary : UiColor.outline })
              Text(category.category || '未分类').fontSize(14).fontColor(UiColor.secondary).layoutWeight(1).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${category.count}`).fontSize(12).fontColor(UiColor.secondary)
            }.width('100%').constraintSize({ minHeight: 48 }).borderRadius(24)
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              .backgroundColor(this.activeCategoryValues.includes(category.category) ? UiColor.selected : Color.Transparent)
              .accessibilityText(`${this.activeCategoryValues.includes(category.category) ? '已选择' : '未选择'}，${category.category || '未分类'}，${category.count} 个未完成任务`)
              .enabled(!this.categoryBusy).onClick(() => { this.toggleCategory(category) })
          }, (category: CoreTaskCategory) => category.key)

          Divider().color(UiColor.outline).margin({ top: 8, bottom: 8 })
          this.navItem('笔记本', $r('app.media.ui_folder'), 'pages/Files', this.activeRoute === 'pages/Files')
          this.navItem('存储库', $r('app.media.ui_cloud'), 'pages/Repositories', this.activeRoute === 'pages/Repositories')
          this.navItem('设置', $r('app.media.ui_settings'), 'pages/Settings', this.activeRoute === 'pages/Settings')
          if (this.navMessage.length > 0) {
            Text(this.navMessage).fontSize(12).fontColor(UiColor.error).padding(16)
          }
        }.width('100%').padding({ left: 12, right: 12, bottom: 16 })
      }.layoutWeight(1).width('100%').align(Alignment.TopStart)
      Divider().color(UiColor.outline)
      this.navItem('同步', $r('app.media.ui_sync'), 'pages/Index', this.activeRoute === 'pages/Index')
    }.width('84%').constraintSize({ maxWidth: 340 }).height('100%').backgroundColor(UiColor.container)
      .borderRadius({ topRight: 20, bottomRight: 20 })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Row() {
          IconButton({ icon: this.back ? $r('app.media.ui_back') : $r('app.media.ui_menu'),
            label: this.back ? '返回' : '打开导航', disabled: this.busy,
            action: () => { if (this.back) this.backAction(); else this.openDrawer() } })
          Text(this.title).fontSize(22).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ left: 8 })
          if (this.actionLabel.length > 0) {
            IconButton({ icon: this.actionIcon, label: this.actionLabel, disabled: this.busy, action: this.action })
          }
          if (this.extraLabel.length > 0) {
            IconButton({ icon: this.extraIcon, label: this.extraLabel, disabled: this.busy, action: this.extraAction })
          }
        }.width('100%').height(64).padding({ left: 4, right: 4 }).backgroundColor(UiColor.surface)
        Divider().color(UiColor.outline).strokeWidth(0.5)
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
