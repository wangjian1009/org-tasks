import { router } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { EmptyState, MessageBar, SectionHeading } from '../components/Controls'
import { BUILTIN_SEARCHES, SavedSearch, SavedSearchService } from '../services/SavedSearchService'
import { CoreBridgeError, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'

@Entry
@Component
struct SavedSearches {
  @State searches: SavedSearch[] = []
  @State query: string = ''
  @State name: string = ''
  @State editingId: string = ''
  @State editing: boolean = false
  @State saving: boolean = false
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false

  onPageShow() { this.loadSearches() }
  onBackPress(): boolean {
    if (this.saving) return true
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    if (this.editing) { this.editing = false; return true }
    return false
  }

  async loadSearches() {
    try { this.searches = await SavedSearchService.load(getContext(this)); this.message = '' }
    catch (e) { this.message = `读取搜索失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.loading = false }
  }

  async saveSearch() {
    if (this.saving || !this.editingId) return
    if (!this.name.trim()) { this.message = '请输入搜索名称'; return }
    this.saving = true
    try {
      const search: SavedSearch = { id: this.editingId, name: this.name.trim(), query: this.query.trim() }
      const updated = this.searches.filter((item: SavedSearch) => item.id !== search.id).concat([search])
      await SavedSearchService.save(getContext(this), updated)
      this.searches = updated
      this.editing = false
      this.message = ''
    } catch (e) { this.message = `保存搜索失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.saving = false }
  }

  edit(search: SavedSearch) {
    this.editingId = search.id; this.name = search.name; this.query = search.query; this.editing = true; this.message = ''
  }

  confirmDelete(search: SavedSearch) {
    this.getUIContext().showAlertDialog({ title: '删除已保存搜索？', message: `删除“${search.name}”不会删除笔记。`,
      primaryButton: { value: '取消', action: () => {} }, secondaryButton: { value: '删除', action: (): void => { this.remove(search) } } })
  }

  async remove(search: SavedSearch) {
    try {
      const updated = this.searches.filter((item: SavedSearch) => item.id !== search.id)
      await SavedSearchService.save(getContext(this), updated)
      this.searches = updated
    } catch (e) { this.message = `删除搜索失败：${coreErrorMessage(e as CoreBridgeError)}` }
  }

  @Builder
  searchItem(search: SavedSearch, editable: boolean) {
    Column({ space: 5 }) {
      Text(search.name).fontSize(18).fontColor(UiColor.text).width('100%')
      Text(search.query || '全部笔记').fontSize(13).fontColor(UiColor.secondary).width('100%').maxLines(2)
    }.width('100%').padding(16).border({ width: { bottom: 0.5 }, color: UiColor.outline })
      .onClick((): void => { router.pushUrl({ url: 'pages/Search', params: { query: search.query, name: search.name, run: true } }) })
      .gesture(LongPressGesture().onAction(() => {
        if (editable) this.getUIContext().showActionSheet({ message: '', title: search.name, sheets: [
          { title: '编辑', action: (): void => { this.edit(search) } }, { title: '删除', action: (): void => { this.confirmDelete(search) } }
        ] })
      }))
  }

  build() {
    Column() {
      AppShell({ title: this.editing ? '编辑搜索' : '搜索', titleIcon: $r('app.media.nav_search'), activeRoute: 'pages/SavedSearches', back: this.editing, drawerOpen: $drawerOpen,
      busy: this.saving, backAction: () => { this.editing = false },
      actionIcon: this.editing ? $r('app.media.ui_done') : $r('app.media.ui_search'), actionLabel: this.editing ? '保存搜索' : '搜索笔记',
      action: () => { if (this.editing) this.saveSearch(); else router.pushUrl({ url: 'pages/Search' }) } }) {
        Column() {
          MessageBar({ message: this.message, error: true })
          if (this.editing) {
            Scroll() {
              Column({ space: 16 }) {
                Text('名称').fontSize(13).fontColor(UiColor.primary).width('100%')
                TextInput({ placeholder: '例如：工作待办', text: this.name }).height(56).borderRadius(6).backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary)
                  .onChange((value: string) => { this.name = value })
                Text('查询表达式').fontSize(13).fontColor(UiColor.primary).width('100%')
                TextArea({ placeholder: '例如：i.todo t.work；留空显示全部笔记', text: this.query }).height(120)
                  .borderRadius(6).backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary).onChange((value: string) => { this.query = value })
                Button(this.saving ? '保存中…' : '保存').width('100%').height(48).backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary)
                  .enabled(!this.saving).onClick((): void => { this.saveSearch() })
              }.width('100%').padding(24).enabled(!this.saving)
            }.width('100%').layoutWeight(1).align(Alignment.TopStart)
          } else if (this.loading) {
            EmptyState({ title: '正在读取已保存搜索', busy: true })
          } else {
            List() {
              ListItem() { SectionHeading({ title: '快捷搜索' }) }
              ForEach(BUILTIN_SEARCHES, (search: SavedSearch) => {
                ListItem() { this.searchItem(search, false) }
              }, (search: SavedSearch) => `${search.id}:${search.name}:${search.query}`)
              ListItem() { SectionHeading({ title: '已保存搜索', subtitle: this.searches.length === 0 ? '暂无已保存搜索' : '长按可编辑或删除' }) }
              ForEach(this.searches, (search: SavedSearch) => {
                ListItem() { this.searchItem(search, true) }
              }, (search: SavedSearch) => `${search.id}:${search.name}:${search.query}`)
            }.width('100%').layoutWeight(1).align(Alignment.TopStart).padding({ bottom: 16 })
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
