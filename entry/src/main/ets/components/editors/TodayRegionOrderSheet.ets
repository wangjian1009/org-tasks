import { TodayRegionOrder, TodayProjectOrder, TodayOrderRegion, TodayOrderProject, orderedTodayCatalog } from '../../ui/TodayRegionOrderPresentation'
import { coreErrorMessage, CoreBridgeError } from '../../services/NativeCoreService'
import { UiColor } from '../../ui/Theme'

export class TodayRegionOrderSheetController {
  requestClose: () => void = () => {}
}

@Component
export struct TodayRegionOrderSheet {
  @Prop catalog: TodayOrderRegion[] = []
  @Prop initialOrder: TodayRegionOrder | null = null
  @Prop readError: string = ''
  @Link visible: boolean
  @Link busy: boolean
  controller: TodayRegionOrderSheetController = new TodayRegionOrderSheetController()
  save: (draft: TodayOrderRegion[], reset: boolean) => Promise<void> = async () => {}
  @State draft: TodayOrderRegion[] = []
  @State expanded: string[] = []
  @State resetDraft: boolean = false
  @State readErrorCleared: boolean = false
  @State message: string = ''
  private original: string = ''

  aboutToAppear(): void {
    this.draft = orderedTodayCatalog(this.catalog, this.initialOrder)
    this.original = this.signature()
    this.controller.requestClose = (): void => { this.cancel() }
  }

  aboutToDisappear(): void { this.controller.requestClose = (): void => {} }

  private signature(): string {
    return JSON.stringify(this.draft.map((region): TodayProjectOrder => ({ region: region.key, keys: region.projects.map(project => project.key) })))
  }

  cancel(): void {
    if (this.busy) return
    if (this.resetDraft || this.signature() !== this.original) {
      this.getUIContext().showAlertDialog({ title: '放弃顺序调整？', message: '本次调整尚未保存。',
        primaryButton: { value: '继续编辑', action: (): void => {} },
        secondaryButton: { value: '放弃', action: (): void => { this.visible = false } } })
    } else this.visible = false
  }

  toggle(region: TodayOrderRegion): void {
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
    this.draft = orderedTodayCatalog(this.catalog, null)
    this.resetDraft = true
    this.readErrorCleared = true
    this.message = ''
  }

  async confirm(): Promise<void> {
    if (this.busy || (!!this.readError && !this.readErrorCleared)) return
    this.busy = true; this.message = ''
    try { await this.save(this.draft, this.resetDraft); this.visible = false }
    catch (error) { this.message = `保存失败：${coreErrorMessage(error as CoreBridgeError)}` }
    finally { this.busy = false }
  }

  @Builder
  handle(label: string) {
    Image($r('app.media.ui_drag_handle')).width(24).height(24).margin({ left: 8, right: 8 }).draggable(false)
      .accessibilityText(`长按拖动${label}`)
  }

  @Builder
  regionHeader(region: TodayOrderRegion) {
    Row({ space: 8 }) {
      if (region.projects.length > 0) {
        Text(this.expanded.includes(region.key) ? '⌄' : '›').fontSize(22).fontColor(UiColor.secondary).width(20).textAlign(TextAlign.Center)
      } else { Row().width(20) }
      Image(region.key === 'schedule' ? $r('app.media.nav_planned') : $r('app.media.ui_category')).width(22).height(22).draggable(false)
      Text(region.title).fontSize(16).fontColor(UiColor.text).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (region.taskCount === 0) { Text('暂无任务').fontSize(12).fontColor(UiColor.secondary) }
      this.handle(region.title)
    }.id(`today_order_region:${region.key}`).height(56).width('100%')
      .onClick((): void => { this.toggle(region) })
  }

  @Builder
  projectRow(project: TodayOrderProject) {
    Row({ space: 8 }) {
      Text(project.title).fontSize(15).fontColor(UiColor.text).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (project.taskCount === 0) { Text('暂无任务').fontSize(12).fontColor(UiColor.secondary) }
      this.handle(project.title)
    }.id(`today_order_project:${project.key}`).height(48).width('100%').padding({ left: 56 })
  }

  build() {
    Column() {
      Row() {
        Button('取消').id('today_order_cancel').fontColor(UiColor.secondary).backgroundColor(Color.Transparent)
          .enabled(!this.busy).onClick((): void => { this.cancel() })
        Text('调整分区顺序').fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text).layoutWeight(1).textAlign(TextAlign.Center)
        Button(this.busy ? '保存中' : '完成').id('today_order_done').fontColor(UiColor.primary).backgroundColor(Color.Transparent)
          .enabled(!this.busy && (!this.readError || this.readErrorCleared)).onClick((): void => { this.confirm() })
      }.height(56).width('100%')
      Text('长按拖动调整顺序，点击分类展开项目；普通任务固定在项目下方。')
        .fontSize(13).fontColor(UiColor.secondary).padding({ left: 20, right: 20, bottom: 12 }).width('100%')
      if (this.message || (this.readError && !this.readErrorCleared)) {
        Text(this.message || this.readError).fontSize(13).fontColor(UiColor.error).padding(12).width('100%')
      }
      List() {
        ForEach(this.draft, (region: TodayOrderRegion) => {
          ListItem() {
            Column() {
              this.regionHeader(region)
              if (this.expanded.includes(region.key) && region.projects.length > 0) {
                List() {
                  ForEach(region.projects, (project: TodayOrderProject) => {
                    ListItem() { this.projectRow(project) }
                  }, (project: TodayOrderProject) => project.key)
                    .onMove((from: number, to: number): void => { this.moveProject(region.key, from, to) })
                }.height(region.projects.length * 48).width('100%').enableScrollInteraction(false)
              }
              Divider().color(UiColor.outline).strokeWidth(0.5)
            }.width('100%')
          }
        }, (region: TodayOrderRegion) => region.key)
          .onMove((from: number, to: number): void => { this.moveRegion(from, to) },
            { onDragStart: (_index: number): void => { this.expanded = [] } })
      }.id('today_order_list').layoutWeight(1).width('100%').padding({ left: 12, right: 12 })
        .enabled(!this.busy).edgeEffect(EdgeEffect.None)
      Button('恢复默认顺序').id('today_order_reset').height(48).fontColor(UiColor.primary).backgroundColor(Color.Transparent)
        .enabled(!this.busy).onClick((): void => { this.restoreDefaults() })
    }.width('100%').height('100%').padding({ bottom: 16 }).backgroundColor(UiColor.container)
  }
}
