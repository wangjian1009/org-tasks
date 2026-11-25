import { localizedText } from '../../ui/LocalizedText'
import { CoreRefileTarget } from '../../services/NativeCoreService'
import { MoveTargetHistoryService } from '../../services/MoveTargetHistoryService'
import { RefileRow, RefileSection, recentRefileRows, refileRows, refileTargetKey, searchRefileRows } from '../../ui/MoveToTargetPresentation'
import { UiColor, UiSize } from '../../ui/Theme'

@Builder
function emptySourcePreview() {}

@Component
export struct MoveToTarget {
  @BuilderParam sourcePreview: () => void = emptySourcePreview
  @Prop @Watch('sectionsChanged') sections: RefileSection[] = []
  @Prop @Watch('sectionsChanged') repositoryNames: Map<string, string> = new Map()
  @Prop @Watch('resetSelection') selectionKey: string = ''
  @Prop loading: boolean = false
  @Prop busy: boolean = false
  @Prop message: string = ''
  @State selectedKey: string = ''
  @State query: string = ''
  @State searchFocused: boolean = false
  @State expanded: string[] = []
  @State collapsedSearch: string[] = []
  @State previewMaxHeight: number = 200
  @State rows: RefileRow[] = []
  @State matching: RefileRow[] = []
  @State recentRows: RefileRow[] = []
  @State defaultRow: RefileRow | undefined = undefined
  @State historyMessage: string = ''
  private recent: string[] = []
  private disposed: boolean = false
  private scroller: ListScroller = new ListScroller()
  private rowsByKey: Map<string, RefileRow> = new Map()
  choose: (target: CoreRefileTarget) => void = () => {}
  retry: () => void = () => {}
  close: () => void = () => {}

  aboutToAppear(): void {
    this.disposed = false
    this.sectionsChanged()
    this.loadHistory()
  }

  aboutToDisappear(): void { this.disposed = true }

  async loadHistory(): Promise<void> {
    try {
      const recent = await MoveTargetHistoryService.load(this.getUIContext().getHostContext()!)
      if (this.disposed) return
      this.recent = recent
      this.historyMessage = ''
      this.recentRows = recentRefileRows(this.rows, recent)
    } catch (_) {
      if (!this.disposed) this.historyMessage = localizedText($r('app.string.text_recent_position_reading_failed_tap_to_try'))
    }
  }

  resetSelection(): void { this.selectedKey = '' }

  sectionsChanged(): void {
    this.rows = refileRows(this.sections, this.repositoryNames)
    this.rowsByKey.clear()
    this.rows.forEach((row: RefileRow): void => { this.rowsByKey.set(row.key, row) })
    if (this.rows.length && !this.rowsByKey.has(this.selectedKey)) this.resetSelection()
    this.defaultRow = this.rows.find(row => !row.target.fullPath.titles.length && row.target.projectName === null)
    this.recentRows = recentRefileRows(this.rows, this.recent)
    this.matching = this.query.trim() ? searchRefileRows(this.rows, this.query) : []
  }

  changeQuery(value: string): void {
    this.query = value
    this.matching = value.trim() ? searchRefileRows(this.rows, value) : []
    this.collapsedSearch = []
    if (value.trim() && !this.matching.some(row => row.key === this.selectedKey)) this.resetSelection()
    try { this.scroller.scrollToIndex(0) } catch (_) { /* 列表尚未布局。 */ }
  }

  sectionExpanded(section: RefileSection, search: boolean): boolean {
    return search ? !this.collapsedSearch.includes(section.key) : this.expanded.includes(section.key)
  }

  toggle(section: RefileSection, search: boolean): void {
    if (search) {
      this.collapsedSearch = this.collapsedSearch.includes(section.key) ?
        this.collapsedSearch.filter(key => key !== section.key) : this.collapsedSearch.concat(section.key)
      return
    }
    this.expanded = this.expanded.includes(section.key) ?
      this.expanded.filter(key => key !== section.key) : this.expanded.concat(section.key)
  }

  select(row: RefileRow): void {
    if (this.busy || this.loading) return
    this.selectedKey = row.key
    if (this.query.trim()) this.getUIContext().getFocusController().clearFocus()
  }

  move(row: RefileRow): void {
    if (this.busy || this.loading || this.selectedKey !== row.key) return
    const current = this.rowsByKey.get(row.key)
    if (current) this.choose(current.target)
  }

  projectRow(section: RefileSection): RefileRow | undefined {
    if (section.kind !== 'project') return undefined
    const root = section.targets.find(target => !target.fullPath.titles.length)
    return root ? this.rowsByKey.get(refileTargetKey(root)) : undefined
  }

  sectionRows(section: RefileSection): RefileRow[] {
    const rows: RefileRow[] = []
    for (const target of section.targets) {
      if (!target.fullPath.titles.length) continue
      const row = this.rowsByKey.get(refileTargetKey(target))
      if (row) rows.push(row)
    }
    return rows
  }

  searchSections(): RefileSection[] {
    const matched = new Set(this.matching.map(row => row.key))
    return this.sections.filter(section => {
      const root = this.projectRow(section)
      return root !== undefined && matched.has(root.key)
    })
  }

  searchSectionRows(section: RefileSection): RefileRow[] {
    const matched = new Set(this.matching.map(row => row.key))
    return this.sectionRows(section).filter(row => matched.has(row.key))
  }

  ungroupedMatches(): RefileRow[] {
    const grouped = new Set<string>()
    for (const section of this.searchSections()) {
      for (const target of section.targets) grouped.add(refileTargetKey(target))
    }
    return this.matching.filter(row => !grouped.has(row.key))
  }

  @Builder
  moveButton(row: RefileRow) {
    Button($r('app.string.text_move')).id('move_to_target').width(58).height(32).padding(0).borderRadius(8)
      .backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary).fontSize(14)
      .accessibilityText(localizedText($r('app.string.text_move_to'), String(row.title), String(row.context)))
      .enabled(!this.busy && !this.loading).onClick((): void => { this.move(row) })
  }

  @Builder
  searchBar() {
    Row({ space: 9 }) {
      Image($r('app.media.ui_search')).width(18).height(18).fillColor(UiColor.secondary).accessibilityLevel('no')
      TextInput({ text: this.query, placeholder: localizedText($r('app.string.text_search_location_item_or_category')) }).id('move_target_search')
        .layoutWeight(1).height('100%').padding(0).backgroundColor(Color.Transparent)
        .fontColor(UiColor.text).placeholderColor(UiColor.secondary).fontSize(14)
        .accessibilityText($r('app.string.move_destination_search')).enterKeyType(EnterKeyType.Search)
        .onFocus((): void => { this.searchFocused = true })
        .onBlur((): void => { this.searchFocused = false })
        .onChange((value: string): void => { this.changeQuery(value) })
      if (this.query) {
        Image($r('app.media.ui_close')).width(32).height(36).padding(7).fillColor(UiColor.secondary)
          .accessibilityText($r('app.string.text_clear_search')).onClick((): void => { this.changeQuery('') })
      }
    }.width('100%').height(40).padding({ left: 12, right: 4 }).borderRadius(9)
      .backgroundColor('#2D312F').border({ width: 1, color: UiColor.outline })
      .enabled(!this.busy)
  }

  @Builder
  caption(label: string) {
    Text(label).width('100%').height(32).padding({ left: 10 })
      .fontSize(13).fontColor(UiColor.secondary).fontWeight(FontWeight.Medium)
  }

  @Builder
  targetRow(row: RefileRow, indent: number = 0) {
    Row({ space: 10 }) {
      Image(row.target.fullPath.titles.length ? $r('app.media.ui_body') :
        row.target.projectName === null ? $r('app.media.ui_document_outline') : $r('app.media.ui_folder'))
        .width(16).height(16).fillColor(this.selectedKey === row.key ? UiColor.primary : UiColor.secondary)
        .accessibilityLevel('no')
      Column({ space: 1 }) {
        Text(row.title).fontSize(15).fontColor(UiColor.text)
          .fontWeight(this.selectedKey === row.key ? FontWeight.Medium : FontWeight.Normal)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(row.context).fontSize(11).fontColor(UiColor.secondary)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).constraintSize({ minWidth: 0 })
        .accessibilityText(`${row.title}，${row.context}${this.selectedKey === row.key ? localizedText($r('app.string.text_selected_2')) : ''}`)
        .onClick((): void => { this.select(row) })
      if (this.selectedKey === row.key) this.moveButton(row)
    }.width('100%').constraintSize({ minHeight: 46 }).padding({ left: 10 + indent, right: 8, top: 4, bottom: 4 })
      .backgroundColor(this.selectedKey === row.key ? '#3F514A' : Color.Transparent)
      .border({ width: this.selectedKey === row.key ? 1 : 0, color: UiColor.primary }).borderRadius(9)
      .enabled(!this.busy && !this.loading).onClick((): void => { this.select(row) })
  }

  @Builder
  sectionHeader(section: RefileSection, root: RefileRow | undefined, children: RefileRow[], search: boolean = false) {
    Row({ space: 6 }) {
      Row({ space: 10 }) {
        Image(section.kind === 'project' ? $r('app.media.ui_folder') : $r('app.media.ui_category_muted'))
          .width(16).height(16).fillColor(UiColor.secondary).accessibilityLevel('no')
        Column({ space: 1 }) {
          Text(section.name || localizedText($r('app.string.text_uncategorized'))).fontSize(15).fontColor(UiColor.text).fontWeight(FontWeight.Medium)
            .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (root && (root.context !== root.target.path || this.selectedKey === root.key)) {
            Text(root.context).fontSize(11).fontColor(UiColor.secondary)
              .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).constraintSize({ minWidth: 0 })
      }.layoutWeight(1).constraintSize({ minHeight: 44 }).padding({ left: 10 })
        .accessibilityText(root ? localizedText($r('app.string.text_select_the_item_root_position'), String(section.name)) : section.name || localizedText($r('app.string.text_uncategorized')))
        .onClick((): void => { if (root) this.select(root); else this.toggle(section, search) })
      if (children.length) {
        if (root) Divider().vertical(true).height(22).color(UiColor.outline)
        Row() {
          Image($r('app.media.ui_next')).width(14).height(14)
            .rotate({ angle: this.sectionExpanded(section, search) ? 90 : 0 }).fillColor(UiColor.secondary)
        }.width(42).height(44).justifyContent(FlexAlign.Center)
          .id(`move_expand:${section.name || '未分类'}`)
          .accessibilityText(`${this.sectionExpanded(section, search) ? localizedText($r('app.string.text_collapse')) : localizedText($r('app.string.text_expand'))}${section.name || localizedText($r('app.string.text_uncategorized'))}`)
          .onClick((): void => { this.toggle(section, search) })
      }
      if (root && this.selectedKey === root.key) this.moveButton(root)
    }.width('100%').padding({ right: 8 }).borderRadius(9)
      .backgroundColor(root && this.selectedKey === root.key ? '#3F514A' :
        children.length && this.sectionExpanded(section, search) ? '#2D312F' : Color.Transparent)
      .border({ width: root && this.selectedKey === root.key ? 1 : 0, color: UiColor.primary })
      .enabled(!this.busy && !this.loading)
  }

  @Builder
  status(text: string) {
    Text(text).width('100%').height(60).padding({ left: 12 }).fontSize(14).fontColor(UiColor.secondary)
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Image($r('app.media.ui_move_to')).width(24).height(24).accessibilityLevel('no')
        Text($r('app.string.text_move_to_2')).fontSize(20).fontColor(UiColor.text).fontWeight(FontWeight.Medium).layoutWeight(1)
        Image($r('app.media.ui_close')).width(40).height(40).padding(11).fillColor(UiColor.secondary)
          .accessibilityText($r('app.string.text_close_mobile_window')).enabled(!this.busy).onClick(this.close)
      }.width('100%').height(48).padding({ left: 20, right: 20 })
      Scroll() {
        this.sourcePreview()
      }.width('100%').constraintSize({ maxHeight: this.searchFocused ? 72 : this.previewMaxHeight })
        .padding({ left: 16, right: 16 }).margin({ bottom: 10 })
        .nestedScroll({ scrollForward: NestedScrollMode.SELF_ONLY, scrollBackward: NestedScrollMode.SELF_ONLY })
      Row() { this.searchBar() }.width('100%').padding({ left: 20, right: 20, bottom: 8 })
      if (this.historyMessage) {
        Text(this.historyMessage).fontSize(13).fontColor(UiColor.error).padding(12).width('100%')
          .onClick((): void => { this.loadHistory() })
      }
      if (this.busy) this.status(localizedText($r('app.string.text_moving')))
      if (this.message) {
        Text(this.message).fontSize(14).fontColor(UiColor.error).maxLines(3).padding(12).width('100%')
        Button($r('app.string.text_refresh_and_try_again')).height(40).onClick((): void => { this.retry() }).enabled(!this.busy)
      }
      if (this.loading) {
        this.status(localizedText($r('app.string.text_reading_task_targets')))
      } else if (!this.rows.length) {
        this.status(localizedText($r('app.string.text_no_mission_objective_for_now')))
      } else {
        List({ scroller: this.scroller }) {
          if (this.query.trim()) {
            ListItem() { this.caption(localizedText($r('app.string.text_search_results_location'), String(this.matching.length))) }
            if (!this.matching.length) {
              ListItem() { this.status(localizedText($r('app.string.text_no_match_locations'))) }
            }
            ForEach(this.searchSections(), (section: RefileSection) => {
              ListItemGroup({ header: this.sectionHeader(section, this.projectRow(section), this.searchSectionRows(section), true) }) {
                if (this.sectionExpanded(section, true)) {
                  ForEach(this.searchSectionRows(section), (row: RefileRow) => {
                    ListItem() { this.targetRow(row, 24) }
                  }, (row: RefileRow): string => row.key)
                }
              }
            }, (section: RefileSection): string => section.key)
            ForEach(this.ungroupedMatches(), (row: RefileRow) => { ListItem() { this.targetRow(row) } },
              (row: RefileRow): string => row.key)
          } else {
            if (this.recentRows.length) {
              ListItem() { this.caption(localizedText($r('app.string.text_recent_use'))) }
              ForEach(this.recentRows, (row: RefileRow) => { ListItem() { this.targetRow(row) } },
                (row: RefileRow): string => row.key)
              ListItem() { Divider().color(UiColor.divider).margin({ left: 10, right: 10, top: 10 }) }
            }
            ListItem() { this.caption(localizedText($r('app.string.text_all_locations'))) }
            if (this.defaultRow && !this.recentRows.some((row: RefileRow): boolean => row.key === this.defaultRow?.key)) {
              ListItem() { this.targetRow(this.defaultRow!) }
            }
            ForEach(this.sections.filter((section: RefileSection): boolean =>
              section.kind === 'project' || section.targets.some(target => target.fullPath.titles.length > 0)),
              (section: RefileSection) => {
                ListItemGroup({ header: this.sectionHeader(section, this.projectRow(section), this.sectionRows(section)) }) {
                  if (this.expanded.includes(section.key)) {
                    ForEach(this.sectionRows(section), (row: RefileRow) => {
                      ListItem() { this.targetRow(row, 24) }
                    }, (row: RefileRow): string => row.key)
                  }
                }
              }, (section: RefileSection): string => section.key)
          }
        }.width('100%').layoutWeight(1).padding({ left: 14, right: 14, bottom: 12 })
          .edgeEffect(EdgeEffect.None)
          .nestedScroll({ scrollForward: NestedScrollMode.SELF_ONLY, scrollBackward: NestedScrollMode.SELF_ONLY })
      }
    }.width('100%').height('100%').backgroundColor('#363A38').padding({ bottom: 8 })
      .onAreaChange((_old: Area, area: Area): void => {
        const height = parseFloat(area.height.toString())
        if (height > 0) this.previewMaxHeight = Math.max(56, Math.min(200, Math.floor(height * 0.36)))
      })
  }
}
