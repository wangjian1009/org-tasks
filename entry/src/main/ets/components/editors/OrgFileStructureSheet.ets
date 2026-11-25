import { localizedText } from '../../ui/LocalizedText'
import { util } from '@kit.ArkTS'
import { CoreBridgeError, CoreTaskStructureEdit, coreErrorMessage } from '../../services/NativeCoreService'
import { ProjectStructureDraft, OrgFileStructureNode, OrgFileStructureSnapshot, OrgFileStructureRow, OrgFilePlacement, projectSiblings } from '../../ui/OrgFileStructurePresentation'
import { showDangerousConfirmation } from '../controls/DangerousConfirmation'
import { UiColor } from '../../ui/Theme'
import { checklistEdgeScroll } from '../../ui/TaskChecklistReorder'
import { TitleText } from '../TitleText'
import { TaskEditor } from './TaskEditor'

export class OrgFileStructureSheetController {
  back: () => void = () => {}
}

export type OrgFileStructureMode = 'add' | 'order' | 'move'
export type OrgFileStructureNodeKind = 'task' | 'section'

const orderRowHeight = 48

@Component
export struct OrgFileStructureSheet {
  @Prop mode: OrgFileStructureMode = 'add'
  @Prop snapshot: OrgFileStructureSnapshot
  @Prop initialParent: string | null = null
  @Prop initialKind: OrgFileStructureNodeKind = 'task'
  @Prop liveVersion: string = ''
  controller: OrgFileStructureSheetController = new OrgFileStructureSheetController()
  close: () => void = () => {}
  save: (snapshot: OrgFileStructureSnapshot, edits: CoreTaskStructureEdit[]) => Promise<string[]> = async () => []
  reload: (force: boolean) => Promise<OrgFileStructureSnapshot> = async (_force: boolean) => { throw new Error(localizedText($r('app.string.text_project_document_not_yet_loaded'))) }
  created: (row: string) => void = () => {}

  @State parent: string | null = null
  @State titleInput: string = ''
  @State moveQuery: string = ''
  @State moveRows: OrgFileStructureRow[] = []
  @State moveTarget: string | null = null
  @State moveTargetChosen: boolean = false
  private moveSourceRow: string = ''
  @State source: OrgFileStructureSnapshot = { file: { repoId: '', file: null, titles: [] },
    version: '', title: '', nodes: [], hasConflict: false }
  @State ordered: OrgFileStructureNode[] = []
  @State orderChanged: boolean = false
  @State busy: boolean = false
  @State message: string = ''
  @State conflict: boolean = false
  @State dropBefore: string = ''
  @State dropAfter: string = ''
  @State dragId: string = ''
  @State liftedNode: OrgFileStructureNode | undefined = undefined
  @State liftedTop: number = 0
  private dragGrabY: number = 0
  private orderScroller: Scroller = new Scroller()
  private dragPoint: FingerInfo | undefined = undefined
  private dragIndex: number = -1
  private scrollTimer: number = -1
  private draft: ProjectStructureDraft | undefined = undefined
  aboutToAppear(): void {
    this.source = this.snapshot
    this.parent = this.initialParent
    if (this.mode === 'move') this.moveSourceRow = this.source.nodes.find(node => node.id === this.parent)?.row ?? ''
    this.resetDraft()
    this.controller.back = (): void => { this.back() }
  }

  aboutToDisappear(): void {
    this.clearDrop()
    this.controller.back = (): void => {}
  }

  private resetDraft(): void {
    this.draft = new ProjectStructureDraft(this.source)
    this.refresh()
  }

  private refresh(): void {
    if (!this.draft) return
    if (this.mode === 'move') {
      this.moveRows = this.draft.rows(this.source.nodes.map(node => node.id), this.moveQuery)
        .filter(row => this.parent !== null && !this.draft!.covered(row.node.id, [this.parent]))
    } else if (this.mode === 'order') {
      this.ordered = this.draft.siblings(this.parent)
      this.orderChanged = this.draft.changed
    }
  }

  private stale(): boolean {
    return this.conflict || (!!this.liveVersion && this.liveVersion !== this.source.version)
  }

  private back(): void {
    if (this.busy) return
    if (this.mode === 'order' && this.orderChanged) {
      showDangerousConfirmation(this.getUIContext(), { title: localizedText($r('app.string.text_give_up_the_sequence')), message: localizedText($r('app.string.text_this_adjustment_has_not_been_saved')),
        cancelLabel: localizedText($r('app.string.text_continue_sorting')), confirmLabel: localizedText($r('app.string.text_abandon')), onConfirm: (): void => { this.discardOrder() } })
    } else {
      this.close()
    }
  }

  private discardOrder(): void {
    if (!this.busy) this.close()
  }

  private async loadCurrent(): Promise<void> {
    this.busy = true
    this.message = ''
    try {
      const oldParent = this.source.nodes.find(node => node.id === this.parent)
      const latest = await this.reload(true)
      if (oldParent) {
        const current = latest.nodes.find(node => node.row === oldParent.row)
        if (!current) throw new Error(localizedText($r('app.string.text_parent_node_removed_please_reselect_after_closing')))
        this.parent = current.id
      }
      this.source = latest
      this.conflict = false
      this.moveTarget = null
      this.moveTargetChosen = false
      this.resetDraft()
    } catch (error) { this.message = coreErrorMessage(error as CoreBridgeError) }
    finally { this.busy = false }
  }

  private async commit(edits: CoreTaskStructureEdit[]): Promise<void> {
    if (this.busy || this.stale()) return
    this.busy = true
    this.message = ''
    try {
      const rows = await this.save(this.source, edits)
      this.close()
      if (this.mode === 'add' && rows.length === 1) this.created(rows[0])
    } catch (error) {
      this.message = coreErrorMessage(error as CoreBridgeError)
      this.conflict = this.stale() || this.message.includes('版本')
    } finally { this.busy = false }
  }

  private applyForm(): void {
    const title = this.titleInput.trim()
    if (!title || this.busy || this.stale()) return
    this.commit([{ type: 'add', id: util.generateRandomUUID(), title, parent: this.parent, task: this.initialKind === 'task' }])
  }

  private chooseMoveTarget(id: string | null): void {
    this.moveTarget = id
    this.moveTargetChosen = true
    this.message = ''
    this.getUIContext().getFocusController().clearFocus()
  }

  private move(placement: OrgFilePlacement): void {
    const draft = this.draft
    const id = this.parent
    if (!draft || id === null || !this.moveTargetChosen || this.busy || this.stale()) return
    const source = draft.nodes.find(node => node.id === id && node.row === this.moveSourceRow)
    const destination = draft.destination(this.moveTarget, placement, [id])
    if (!source || !destination) return
    const siblings = projectSiblings(draft.nodes, source.parent)
    const index = siblings.findIndex(node => node.id === id)
    const previous = index > 0 ? siblings[index - 1].id : null
    if (source.parent === destination.parent && previous === destination.after) {
      this.message = localizedText($r('app.string.text_this_is_the_location_please_select_another'))
      return
    }
    this.commit([{ type: 'move', ids: [id], parent: destination.parent, after: destination.after }])
  }

  @Builder
  movePosition(title: string, placement: OrgFilePlacement) {
    OrgFileStructureAction({ title, available: !this.busy && !this.stale(), action: (): void => { this.move(placement) } })
  }

  @Builder
  movePanel() {
    Row() {
      Text($r('app.string.text_reposition')).fontSize(19).fontWeight(FontWeight.Medium).fontColor(UiColor.text).layoutWeight(1)
      OrgFileStructureAction({ title: localizedText($r('app.string.text_cancel')), available: !this.busy, action: (): void => { this.back() } })
    }.width('100%')
    Text(this.source.nodes.find(node => node.id === this.parent)?.title ?? '')
      .fontSize(13).fontColor(UiColor.secondary).width('100%').maxLines(2)
    TextInput({ text: this.moveQuery, placeholder: localizedText($r('app.string.text_search_tasks_or_sections')) }).id('project_move_search')
      .height(40).width('100%').fontSize(14).fontColor(UiColor.text).placeholderColor(UiColor.secondary)
      .backgroundColor(UiColor.field).enterKeyType(EnterKeyType.Search).enabled(!this.busy)
      .onChange((value: string): void => { this.moveQuery = value; this.moveTarget = null; this.moveTargetChosen = false; this.refresh() })
    this.status()
    List() {
      if (!this.moveQuery.trim()) {
        ListItem() {
          Text($r('app.string.text_top_level_of_document')).id('project_move_root').fontSize(15).fontColor(UiColor.text).width('100%').height(44)
            .padding({ left: 10 }).borderRadius(8)
            .backgroundColor(this.moveTargetChosen && this.moveTarget === null ? '#3F514A' : Color.Transparent)
            .onClick((): void => { this.chooseMoveTarget(null) })
        }
      }
      ForEach(this.moveRows, (row: OrgFileStructureRow) => {
        ListItem() {
          Row({ space: 8 }) {
            this.nodeIcon(row.node.task)
            Column({ space: 2 }) {
              Text(row.node.title).fontSize(15).fontColor(UiColor.text).width('100%').maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (row.depth > 0) {
                Text(row.path).fontSize(11).fontColor(UiColor.secondary).width('100%').maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }.layoutWeight(1).constraintSize({ minWidth: 0 })
          }.width('100%').constraintSize({ minHeight: 44 }).padding({ left: 10, right: 8 }).borderRadius(8)
            .backgroundColor(this.moveTargetChosen && this.moveTarget === row.node.id ? '#3F514A' : Color.Transparent)
            .onClick((): void => { this.chooseMoveTarget(row.node.id) })
        }
      }, (row: OrgFileStructureRow): string => row.node.id)
      if (this.moveQuery.trim() && !this.moveRows.length) {
        ListItem() { Text($r('app.string.text_no_match_locations')).fontSize(13).fontColor(UiColor.secondary).height(44) }
      }
    }.width('100%').layoutWeight(1).enabled(!this.busy && !this.stale())
    if (this.moveTargetChosen) {
      Text(this.draft?.path(this.moveTarget) ?? '').fontSize(12).fontColor(UiColor.secondary)
        .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      Row() {
        if (this.moveTarget === null) {
          this.movePosition(localizedText($r('app.string.text_move_to_the_beginning')), 'first')
          this.movePosition(localizedText($r('app.string.text_move_to_the_end')), 'last')
        } else {
          this.movePosition(localizedText($r('app.string.text_move_front')), 'before')
          this.movePosition(localizedText($r('app.string.text_move_back')), 'after')
          this.movePosition(localizedText($r('app.string.text_move_to_subpoint')), 'child')
        }
      }.width('100%').justifyContent(FlexAlign.SpaceEvenly)
    }
  }

  private sort(id: string, to: number): void {
    if (this.busy || this.stale()) return
    const node = this.ordered.find(item => item.id === id)
    if (node && this.draft?.reorder(node, to)) {
      this.message = ''
      this.refresh()
    }
  }

  private saveOrder(): void {
    if (this.orderChanged && !this.dragId && this.draft) this.commit(this.draft.edits())
  }

  private clearDrop(): void {
    clearInterval(this.scrollTimer)
    this.scrollTimer = -1
    this.dragPoint = undefined
    this.dragIndex = -1
    this.dragId = ''
    this.liftedNode = undefined
    this.dropBefore = ''
    this.dropAfter = ''
  }

  private startOrderDrag(id: string, event: GestureEvent): void {
    const finger = event.fingerList[0]
    const list = this.getUIContext().getFrameNodeById('project_child_order_list')
    const index = this.ordered.findIndex(node => node.id === id)
    if (this.busy || this.stale() || !finger || !list || index < 0) return
    this.clearDrop()
    this.dragId = id
    const originalTop = index * orderRowHeight - this.orderScroller.currentOffset().yOffset
    this.dragGrabY = finger.globalY - event.offsetY - list.getPositionToWindow().y - originalTop
    this.updateOrderDrag(event)
    this.liftedNode = this.ordered[index]
    this.scrollTimer = setInterval((): void => { this.updateDrop(true) }, 16)
  }

  private updateOrderDrag(event: GestureEvent): void {
    this.dragPoint = event.fingerList[0] ?? this.dragPoint
    this.updateDrop(false)
  }

  private updateDrop(scroll: boolean): void {
    const point = this.dragPoint
    const list = this.getUIContext().getFrameNodeById('project_child_order_list')
    const from = this.ordered.findIndex(node => node.id === this.dragId)
    if (!point || !list || from < 0 || this.busy || this.stale()) {
      this.clearDrop()
      return
    }
    const origin = list.getPositionToWindow()
    const size = list.getMeasuredSize()
    const bottom = origin.y + this.getUIContext().px2vp(size.height)
    const right = origin.x + this.getUIContext().px2vp(size.width)
    const top = origin.y
    const inside = point.globalY >= top && point.globalY <= bottom &&
      point.globalX >= origin.x && point.globalX <= right
    const offset = this.orderScroller.currentOffset().yOffset
    this.liftedTop = point.globalY - top - this.dragGrabY
    const position = this.liftedTop + offset
    const to = Math.max(0, Math.min(this.ordered.length - 1, Math.round(position / orderRowHeight)))
    this.dragIndex = inside ? to : -1
    this.dropBefore = inside && to < from ? this.ordered[to].id : ''
    this.dropAfter = inside && to > from ? this.ordered[to].id : ''
    if (inside && scroll) {
      const speed = checklistEdgeScroll(point.globalY, top, bottom)
      if (speed !== 0) this.orderScroller.scrollBy(0, speed * 0.016)
    }
  }

  private finishOrderDrag(event: GestureEvent): void {
    this.updateOrderDrag(event)
    const id = this.dragId
    const to = this.dragIndex
    this.clearDrop()
    if (id && to >= 0) this.sort(id, to)
  }

  @Builder
  status() {
    if (this.message) {
      Text(this.message).fontSize(13).fontColor(UiColor.error).width('100%').padding({ bottom: 8 })
    }
    if (this.stale()) {
      Text(this.mode === 'order' ? localizedText($r('app.string.text_the_document_has_been_updated_and_please')) : localizedText($r('app.string.text_document_updated_please_reload_structure')))
        .fontSize(13).fontColor(UiColor.error).width('100%')
      if (this.mode !== 'order') {
        OrgFileStructureAction({ title: localizedText($r('app.string.text_reload_structure')), available: !this.busy, action: (): void => { this.loadCurrent() } })
      }
    }
  }

  @Builder
  nodeIcon(task: boolean) {
    if (task) {
      Rect().width(16).height(16).radius(3).fill(Color.Transparent).stroke(UiColor.secondary).strokeWidth(1.5)
        .accessibilityLevel('no')
    } else {
      Image($r('app.media.ui_document_outline')).width(18).height(18).fillColor(UiColor.secondary).accessibilityLevel('no')
    }
  }

  @Builder
  grip(node: OrgFileStructureNode) {
    if (this.ordered.length > 1) {
      Row() {
        Image($r('app.media.ui_drag_handle')).width(24).height(24).draggable(false).accessibilityLevel('no')
      }.width(44).height(44).justifyContent(FlexAlign.Center)
        .accessibilityText(localizedText($r('app.string.text_long_press_drag'), String(node.title)))
        .gesture(GestureGroup(GestureMode.Sequence, LongPressGesture({ repeat: false, duration: 300 }),
          PanGesture({ direction: PanDirection.Vertical, distance: 4 })
            .onActionStart((event: GestureEvent): void => { this.startOrderDrag(node.id, event) })
            .onActionUpdate((event: GestureEvent): void => { this.updateOrderDrag(event) })
            .onActionEnd((event: GestureEvent): void => { this.finishOrderDrag(event) })
            .onActionCancel((): void => { this.clearDrop() })).onCancel((): void => { this.clearDrop() }))
    } else {
      Blank().width(44)
    }
  }

  @Builder
  dropLine(id: string) {
    if (this.dropBefore === id || this.dropAfter === id) {
      Divider().strokeWidth(2).color(UiColor.primary)
        .align(this.dropBefore === id ? Alignment.Top : Alignment.Bottom)
    }
  }

  @Builder
  orderRow(node: OrgFileStructureNode, lifted: boolean) {
    Row({ space: 10 }) {
      if (node.taskPreview) {
        TaskEditor({ previewTask: node.taskPreview, readOnly: true, titleOnly: true }).layoutWeight(1)
      } else {
        this.nodeIcon(node.task)
        TitleText({ text: node.title, parts: node.titleParts, textSize: 16, lineLimit: 1, openLinks: false }).layoutWeight(1)
      }
      if (node.hidden) { Text($r('app.string.text_filter_hidden')).fontSize(12).fontColor(UiColor.secondary) }
      if (lifted) {
        Row() {
          Image($r('app.media.ui_drag_handle')).width(24).height(24)
        }.width(44).height(44).justifyContent(FlexAlign.Center)
      } else {
        this.grip(node)
      }
    }.width('100%').height(orderRowHeight).opacity(!lifted && this.dragId === node.id ? 0 : 1)
      .padding({ left: node.task ? 0 : 8 })
  }

  @Builder
  inputPanel() {
    Column({ space: 12 }) {
      TextInput({ text: this.titleInput, placeholder: this.initialKind === 'task' ? localizedText($r('app.string.text_task_title')) : localizedText($r('app.string.text_chapter_title')) })
        .id('project_structure_title').height(46)
        .backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary)
        .enterKeyType(EnterKeyType.Done).enabled(!this.busy)
        .onChange((value: string): void => { this.titleInput = value }).onSubmit((): void => { this.applyForm() })
      Text(this.formLocation()).fontSize(13).fontColor(UiColor.secondary).width('100%')
      this.status()
    }.width('100%').padding({top: 8, bottom: 12})
  }

  @Builder
  inputActions() {
    Row() {
      Text(this.initialKind === 'task' ? localizedText($r('app.string.text_add_task')) : localizedText($r('app.string.text_add_chapter')))
        .fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text).layoutWeight(1)
      OrgFileStructureAction({ title: localizedText($r('app.string.text_cancel')), available: !this.busy, action: (): void => { this.back() } })
      Button(this.busy ? localizedText($r('app.string.text_saving_2')) : localizedText($r('app.string.text_save')))
        .id('project_structure_save').height(44).fontColor(UiColor.surface).backgroundColor(UiColor.primary)
        .enabled(!this.busy && !this.stale() && !!this.titleInput.trim()).onClick((): void => { this.applyForm() })
    }.width('100%')
  }

  private formLocation(): string {
    const location = this.draft?.path(this.parent) ?? this.source.title
    return `${location} › ${this.parent === null ? localizedText($r('app.string.text_top_level_first')) : localizedText($r('app.string.text_first_of_the_child_node'))}`
  }

  @Builder
  orderPanel() {
    Row() {
      Text($r('app.string.text_reorder_subpoints'))
        .fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text).layoutWeight(1)
      Button($r('app.string.text_abandon')).id('project_child_order_discard').height(44).fontColor(UiColor.secondary)
        .backgroundColor(Color.Transparent).enabled(!this.busy).onClick((): void => { this.discardOrder() })
      Button(this.busy ? localizedText($r('app.string.text_saving_2')) : localizedText($r('app.string.text_save'))).id('project_child_order_save').height(44)
        .fontColor(UiColor.surface).backgroundColor(UiColor.primary)
        .enabled(this.orderChanged && !this.busy && !this.stale() && !this.dragId)
        .onClick((): void => { this.saveOrder() })
    }.width('100%')
    Text(this.draft?.path(this.parent) ?? this.source.title).fontSize(14).fontColor(UiColor.secondary).width('100%')
    this.status()
    if (this.source.hasConflict) {
      Text($r('app.string.text_file_contains_protected_sync_conflicts')).fontSize(13).fontColor(UiColor.secondary).width('100%').padding({top: 6, bottom: 6})
    }
    Stack({ alignContent: Alignment.TopStart }) {
      List({ scroller: this.orderScroller }) {
        ForEach(this.ordered, (node: OrgFileStructureNode) => {
          ListItem() {
            Stack({ alignContent: Alignment.Center }) {
              this.orderRow(node, false)
              this.dropLine(node.id)
            }.width('100%').alignContent(this.dropBefore === node.id ? Alignment.Top : Alignment.Bottom)
              .border({ width: { bottom: 0.5 }, color: UiColor.outline })
              .backgroundColor(this.dragId === node.id ? UiColor.projectBlock : Color.Transparent)
          }
        }, (node: OrgFileStructureNode) => node.id)
      }.id('project_child_order_list').height('100%').width('100%')
        .enableScrollInteraction(this.dragId === '').enabled(!this.busy && !this.stale())
      if (this.liftedNode) {
        Row() { this.orderRow(this.liftedNode, true) }.width('100%').height(orderRowHeight)
          .backgroundColor(UiColor.container).borderRadius(8).shadow({ radius: 8, color: '#52000000', offsetY: 4 })
          .position({ x: 0, y: this.liftedTop }).hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
      }
    }.layoutWeight(1).width('100%').clip(true)
  }

  build() {
    Column({ space: 6 }) {
      if (this.source) {
        if (this.mode === 'add') {
          this.inputActions()
          Scroll() { this.inputPanel() }.width('100%').layoutWeight(1).scrollBar(BarState.Auto).align(Alignment.Top)
        } else if (this.mode === 'move') {
          this.movePanel()
        } else {
          this.orderPanel()
        }
      }
    }.width('100%').height('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 12 }).backgroundColor(UiColor.container)
  }
}


@Component
struct OrgFileStructureAction {
  @Prop title: string = ''
  @Prop available: boolean = true
  action: () => void = () => {}

  build() {
    Button(this.title).fontSize(15).fontColor(UiColor.primary).backgroundColor(Color.Transparent)
      .constraintSize({ minHeight: 44 }).enabled(this.available).onClick(this.action)
  }
}
