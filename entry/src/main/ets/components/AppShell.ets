import { router } from '@kit.ArkUI'
import { UiColor } from '../ui/Theme'
import { IconButton } from './Controls'
import { AppConfigService } from '../services/AppConfigService'
import { Notebook, NotebookService } from '../services/NotebookService'
import { BUILTIN_SEARCHES, SavedSearch, SavedSearchService } from '../services/SavedSearchService'
import { CoreBridgeError, coreErrorMessage } from '../services/NativeCoreService'

@Component
export struct AppShell {
  @Prop title: string = ''
  @Prop activeRoute: string = ''
  @Prop back: boolean = false
  @Prop actionIcon: Resource = $r('app.media.ui_search')
  @Prop actionLabel: string = ''
  @Prop extraIcon: Resource = $r('app.media.ui_more')
  @Prop extraLabel: string = ''
  @Prop fabLabel: string = ''
  @Prop fabIcon: Resource = $r('app.media.ui_add')
  @Prop busy: boolean = false
  @Link drawerOpen: boolean
  @BuilderParam content: () => void
  action: () => void = () => {}
  extraAction: () => void = () => {}
  fabAction: () => void = () => {}
  backAction: () => void = (): void => { router.back() }
  @State notebooks: Notebook[] = []
  @State searches: SavedSearch[] = []
  @State navMessage: string = ''

  async openDrawer() {
    this.drawerOpen = true
    this.navMessage = ''
    try {
      const config = await AppConfigService.load(getContext(this))
      this.searches = await SavedSearchService.load(getContext(this))
      this.notebooks = await NotebookService.load(config.repos)
    } catch (e) {
      this.navMessage = `读取导航失败：${coreErrorMessage(e as CoreBridgeError)}`
    }
  }

  navigate(route: string) {
    this.drawerOpen = false
    if (this.activeRoute !== route) router.replaceUrl({ url: route })
  }

  openSearch(search: SavedSearch) {
    this.drawerOpen = false
    router.replaceUrl({ url: 'pages/Search', params: { query: search.query, name: search.name, run: true } })
  }

  @Builder
  navItem(title: string, icon: Resource, route: string, selected: boolean = false) {
    Row({ space: 20 }) {
      Image(icon).width(22).height(22)
      Text(title).fontSize(15).fontColor(UiColor.text).fontWeight(selected ? FontWeight.Medium : FontWeight.Normal)
    }.width('100%').height(52).padding({ left: 16, right: 16 }).borderRadius(26)
      .backgroundColor(selected ? UiColor.selected : Color.Transparent)
      .onClick((): void => { this.navigate(route) })
  }

  @Builder
  drawer() {
    Column() {
      Row() {
        Text('Org Tasks').fontSize(22).fontWeight(FontWeight.Medium).fontColor(UiColor.primary).layoutWeight(1)
        IconButton({ icon: $r('app.media.ui_close'), label: '关闭导航', action: () => { this.drawerOpen = false } })
      }.width('100%').padding({ left: 20, right: 8, top: 8, bottom: 8 })
      Scroll() {
        Column({ space: 2 }) {
          this.navItem('搜索', $r('app.media.ui_search'), 'pages/SavedSearches', this.activeRoute === 'pages/SavedSearches')
          this.navItem('日程', $r('app.media.ui_calendar'), 'pages/Agenda', this.activeRoute === 'pages/Agenda')
          ForEach(BUILTIN_SEARCHES.concat(this.searches), (search: SavedSearch) => {
            Text(search.name).fontSize(14).fontColor(UiColor.secondary).width('100%').padding({ left: 58, right: 16, top: 15, bottom: 15 })
              .onClick((): void => { this.openSearch(search) })
          }, (search: SavedSearch) => search.id)
          Divider().color(UiColor.outline).margin({ top: 8, bottom: 8 })
          this.navItem('笔记本', $r('app.media.ui_folder'), 'pages/Files', this.activeRoute === 'pages/Files')
          ForEach(this.notebooks, (notebook: Notebook) => {
            Text(notebook.path).fontSize(14).fontColor(UiColor.secondary).width('100%').maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).padding({ left: 58, right: 16, top: 15, bottom: 15 })
              .onClick(() => {
                this.drawerOpen = false
                router.pushUrl({ url: 'pages/FileDetail', params: { repoId: notebook.repoId, path: notebook.path } })
              })
          }, (notebook: Notebook) => notebook.id)
          Divider().color(UiColor.outline).margin({ top: 8, bottom: 8 })
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
