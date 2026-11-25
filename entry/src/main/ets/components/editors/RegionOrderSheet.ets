import { localizedText } from '../../ui/LocalizedText'
import { showDangerousConfirmation } from '../controls/DangerousConfirmation'
import { RegionOrder, ProjectOrder, OrderRegion, OrderProject, orderedRegionCatalog } from '../../ui/RegionOrderPresentation'
import { coreErrorMessage, CoreBridgeError } from '../../services/NativeCoreService'
import { UiColor } from '../../ui/Theme'

export class RegionOrderSheetController {
  requestClose: () => void = () => {}
}

@Component
export struct RegionOrderSheet {
  @Prop catalog: OrderRegion[] = []
  @Prop initialOrder: RegionOrder | null = null
  @Prop readError: string = ''
  @Link visible: boolean
  @Link busy: boolean
  controller: RegionOrderSheetController = new RegionOrderSheetController()
  save: (draft: OrderRegion[], reset: boolean) => Promise<void> = async () => {}
  @State draft: OrderRegion[] = []
  @State expanded: string[] = []
  @State resetDraft: boolean = false
  @State readErrorCleared: boolean = false
  @State message: string = ''
  private original: string = ''

  aboutToAppear(): void {
    this.draft = orderedRegionCatalog(this.catalog, this.initialOrder)
    this.original = this.signature()
    this.controller.requestClose = (): void => { this.cancel() }
  }

  aboutToDisappear(): void { this.controller.requestClose = (): void => {} }

  private signature(): string {
    return JSON.stringify(this.draft.map((region): ProjectOrder => ({ region: region.key, keys: region.projects.map(project => project.key) })))
  }

  cancel(): void {
    if (this.busy) return
    if (this.resetDraft || this.signature() !== this.original) {
      showDangerousConfirmation(this.getUIContext(), { title: localizedText($r('app.string.text_give_up_the_sequence')), message: localizedText($r('app.string.text_this_adjustment_has_not_been_saved')),
        cancelLabel: localizedText($r('app.string.text_continue_editing')),
        confirmLabel: localizedText($r('app.string.text_abandon')), onConfirm: (): void => { this.visible = false } })
    } else this.visible = false
  }

  toggle(region: OrderRegion): void {
    if (this.busy || region.projects.length === 0) return
    this.expanded = this.expanded.includes(region.key) ? this.expanded.filter(key => key !== region.key) : this.expanded.concat(region.key)
  }

  moveRegion(from: number, to: number): void {
    if (this.busy || from < 0 || to < 0 || from >= this.draft.length || to >= this.draft.length || from === to) return
    const next = this.draft.slice(), moved = next.splice(from, 1)[0]
    next.splice(to, 0, moved); this.draft = next; this.resetDraft = false
  }

  moveProject(regionKey: string, from: number, to: number): void {
    if (this.busy) return
    const region = this.draft.find(item => item.key === regionKey)
    if (!region || from < 0 || to < 0 || from >= region.projects.length || to >= region.projects.length || from === to) return
    const projects = region.projects.slice(), moved = projects.splice(from, 1)[0]
    projects.splice(to, 0, moved)
    this.draft = this.draft.map(item => item.key === regionKey ? { key: item.key, title: item.title, taskCount: item.taskCount, projects } : item)
    this.resetDraft = false
  }

  restoreDefaults(): void {
    if (this.busy) return
    this.draft = orderedRegionCatalog(this.catalog, null)
    this.resetDraft = true
    this.readErrorCleared = true
    this.message = ''
  }

  async confirm(): Promise<void> {
    if (this.busy || (!!this.readError && !this.readErrorCleared)) return
    this.busy = true; this.message = ''
    try { await this.save(this.draft, this.resetDraft); this.visible = false }
    catch (error) { this.message = localizedText($r('app.string.text_save_failed'), String(coreErrorMessage(error as CoreBridgeError))) }
    finally { this.busy = false }
  }

  @Builder
  handle(label: string) {
    Image($r('app.media.ui_drag_handle')).width(24).height(24).margin({ left: 8, right: 8 }).draggable(false)
      .accessibilityText(localizedText($r('app.string.text_long_press_drag_2'), String(label)))
  }

  @Builder
  regionHeader(region: OrderRegion) {
    Row({ space: 8 }) {
      if (region.projects.length > 0) {
        Text(this.expanded.includes(region.key) ? '⌄' : '›').fontSize(22).fontColor(UiColor.secondary).width(20).textAlign(TextAlign.Center)
      } else { Row().width(20) }
      Image($r('app.media.ui_category')).width(22).height(22).draggable(false)
      Text(region.title).fontSize(16).fontColor(UiColor.text).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (region.taskCount === 0) { Text($r('app.string.text_no_tasks')).fontSize(12).fontColor(UiColor.secondary) }
      this.handle(region.title)
    }.id(`region_order_region:${region.key}`).height(56).width('100%')
      .onClick((): void => { this.toggle(region) })
  }

  @Builder
  projectRow(project: OrderProject) {
    Row({ space: 8 }) {
      Text(project.title).fontSize(15).fontColor(UiColor.text).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (project.taskCount === 0) { Text($r('app.string.text_no_tasks')).fontSize(12).fontColor(UiColor.secondary) }
      this.handle(project.title)
    }.id(`region_order_project:${project.key}`).height(48).width('100%').padding({ left: 56 })
  }

  build() {
    Column() {
      Row() {
        Button($r('app.string.text_cancel')).id('region_order_cancel').fontColor(UiColor.secondary).backgroundColor(Color.Transparent)
          .enabled(!this.busy).onClick((): void => { this.cancel() })
        Text($r('app.string.text_sort')).fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text).layoutWeight(1).textAlign(TextAlign.Center)
        Button(this.busy ? localizedText($r('app.string.text_saving')) : localizedText($r('app.string.text_done'))).id('region_order_done').fontColor(UiColor.primary).backgroundColor(Color.Transparent)
          .enabled(!this.busy && (!this.readError || this.readErrorCleared)).onClick((): void => { this.confirm() })
      }.height(56).width('100%')
      Text($r('app.string.text_long_grouping_and_items_by_drag_agenda'))
        .fontSize(13).fontColor(UiColor.secondary).padding({ left: 20, right: 20, bottom: 12 }).width('100%')
      if (this.message || (this.readError && !this.readErrorCleared)) {
        Text(this.message || this.readError).fontSize(13).fontColor(UiColor.error).padding(12).width('100%')
      }
      List() {
        ForEach(this.draft, (region: OrderRegion) => {
          ListItem() {
            Column() {
              this.regionHeader(region)
              if (this.expanded.includes(region.key) && region.projects.length > 0) {
                List() {
                  ForEach(region.projects, (project: OrderProject) => {
                    ListItem() { this.projectRow(project) }
                  }, (project: OrderProject) => project.key)
                    .onMove((from: number, to: number): void => { this.moveProject(region.key, from, to) })
                }.height(region.projects.length * 48).width('100%').enableScrollInteraction(false).scrollBar(BarState.Off)
              }
              Divider().color(UiColor.outline).strokeWidth(0.5)
            }.width('100%')
          }
        }, (region: OrderRegion) => region.key)
          .onMove((from: number, to: number): void => { this.moveRegion(from, to) },
            { onDragStart: (_index: number): void => { this.expanded = [] } })
      }.id('region_order_list').layoutWeight(1).width('100%').padding({ left: 12, right: 12 })
        .enabled(!this.busy).edgeEffect(EdgeEffect.None).scrollBar(BarState.Off)
      Button($r('app.string.text_restore_default_order')).id('region_order_reset').height(48).fontColor(UiColor.primary).backgroundColor(Color.Transparent)
        .enabled(!this.busy).onClick((): void => { this.restoreDefaults() })
    }.width('100%').height('100%').padding({ bottom: 16 }).backgroundColor(UiColor.container)
  }
}
