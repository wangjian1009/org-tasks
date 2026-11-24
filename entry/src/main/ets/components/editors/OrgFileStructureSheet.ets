import { util } from '@kit.ArkTS'
import { CoreBridgeError, CoreTaskStructureEdit, coreErrorMessage } from '../../services/NativeCoreService'
import { ProjectStructureDraft, OrgFileStructureNode, OrgFileStructureSnapshot, OrgFileStructureRow, OrgFilePlacement, projectOrderMove, projectSiblings } from '../../ui/OrgFileStructurePresentation'
import { UiColor } from '../../ui/Theme'
import { checklistEdgeScroll } from '../../ui/TaskChecklistReorder'
import { TitleText } from '../TitleText'

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
  reload: (force: boolean) => Promise<OrgFileStructureSnapshot> = async (_force: boolean) => { throw new Error('项目文件尚未载入') }
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
  @State busy: boolean = false
  @State message: string = ''
  @State conflict: boolean = false
  @State dropBefore: string = ''
  @State dropAfter: string = ''
  @State dragId: string = ''
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
    } else this.ordered = projectSiblings(this.draft.nodes, this.parent)
  }

  private stale(): boolean {
    return this.conflict || (!!this.liveVersion && this.liveVersion !== this.source.version)
  }

  private back(): void {
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
        if (!current) throw new Error('父节点已移除，请关闭面板后重新选择')
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

  private async commit(edits: CoreTaskStructureEdit[], finish: boolean): Promise<void> {
    if (this.busy || this.stale()) return
    this.busy = true
    this.message = ''
    try {
      const rows = await this.save(this.source, edits)
      if (finish) {
        this.close()
        if (this.mode === 'add' && rows.length === 1) this.created(rows[0])
      } else await this.updateOrderAfterCommit()
    } catch (error) {
      this.message = coreErrorMessage(error as CoreBridgeError)
      this.conflict = this.stale() || this.message.includes('版本')
      if (!finish && this.conflict) await this.updateOrderAfterCommit()
    } finally { this.busy = false }
  }

  private async updateOrderAfterCommit(): Promise<void> {
    const oldParent = this.source.nodes.find(node => node.id === this.parent)
    try {
      const latest = await this.reload(this.conflict)
      if (oldParent) {
        const current = latest.nodes.find(node => node.row === oldParent.row)
        if (!current) throw new Error('父节点已移除，请重新选择')
        this.parent = current.id
      }
      this.source = latest
      this.resetDraft()
      this.conflict = false
    } catch (error) {
      this.conflict = true
      this.message = coreErrorMessage(error as CoreBridgeError)
    }
  }

  private applyForm(): void {
    const title = this.titleInput.trim()
    if (!title || this.busy || this.stale()) return
    this.commit([{ type: 'add', id: util.generateRandomUUID(), title, parent: this.parent, task: this.initialKind === 'task' }], true)
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
      this.message = '已在此位置，请选择其他位置'
      return
    }
    this.commit([{ type: 'move', ids: [id], parent: destination.parent, after: destination.after }], true)
  }

  @Builder
  movePosition(title: string, placement: OrgFilePlacement) {
    OrgFileStructureAction({ title, available: !this.busy && !this.stale(), action: (): void => { this.move(placement) } })
  }

  @Builder
  movePanel() {
    Row() {
      Text('调整位置').fontSize(19).fontWeight(FontWeight.Medium).fontColor(UiColor.text).layoutWeight(1)
      OrgFileStructureAction({ title: '取消', available: !this.busy, action: (): void => { this.back() } })
    }.width('100%')
    Text(this.source.nodes.find(node => node.id === this.parent)?.title ?? '')
      .fontSize(13).fontColor(UiColor.secondary).width('100%').maxLines(2)
    TextInput({ text: this.moveQuery, placeholder: '搜索任务或章节' }).id('project_move_search')
      .height(40).width('100%').fontSize(14).fontColor(UiColor.text).placeholderColor(UiColor.secondary)
      .backgroundColor(UiColor.field).enterKeyType(EnterKeyType.Search).enabled(!this.busy)
      .onChange((value: string): void => { this.moveQuery = value; this.moveTarget = null; this.moveTargetChosen = false; this.refresh() })
    this.status()
    List() {
      if (!this.moveQuery.trim()) {
        ListItem() {
          Text('文档顶层').id('project_move_root').fontSize(15).fontColor(UiColor.text).width('100%').height(44)
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
        ListItem() { Text('没有匹配的位置').fontSize(13).fontColor(UiColor.secondary).height(44) }
      }
    }.width('100%').layoutWeight(1).enabled(!this.busy && !this.stale())
    if (this.moveTargetChosen) {
      Text(this.draft?.path(this.moveTarget) ?? '').fontSize(12).fontColor(UiColor.secondary)
        .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      Row() {
        if (this.moveTarget === null) {
          this.movePosition('移到开头', 'first')
          this.movePosition('移到末尾', 'last')
        } else {
          this.movePosition('移到前面', 'before')
          this.movePosition('移到后面', 'after')
          this.movePosition('移为子项', 'child')
        }
      }.width('100%').justifyContent(FlexAlign.SpaceEvenly)
    }
  }

  private sort(id: string, to: number): void {
    if (this.busy || this.stale()) return
    const position = projectOrderMove(this.draft!.nodes, id, to)
    if (!position) return
    this.commit([{ type: 'move', ids: [id], parent: position.parent, after: position.after }], false)
  }

  private clearDrop(): void {
    clearInterval(this.scrollTimer)
    this.scrollTimer = -1
    this.dragPoint = undefined
    this.dragIndex = -1
    this.dragId = ''
    this.dropBefore = ''
    this.dropAfter = ''
  }

  private startOrderDrag(id: string, event: GestureEvent): void {
    if (this.busy || this.stale()) return
    this.clearDrop()
    this.dragId = id
    this.updateOrderDrag(event)
    this.scrollTimer = setInterval((): void => { this.updateDrop(true) }, 24)
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
    const position = point.globalY - top + offset
    const to = Math.max(0, Math.min(this.ordered.length - 1, Math.floor(position / orderRowHeight)))
    this.dragIndex = inside ? to : -1
    this.dropBefore = inside && to < from ? this.ordered[to].id : ''
    this.dropAfter = inside && to > from ? this.ordered[to].id : ''
    if (inside && scroll) {
      const speed = checklistEdgeScroll(point.globalY, top, bottom)
      if (speed !== 0) this.orderScroller.scrollBy(0, speed * 0.024)
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
      Text('文件已更新，请重新载入结构').fontSize(13).fontColor(UiColor.error).width('100%')
      OrgFileStructureAction({ title: '重新载入结构', available: !this.busy, action: (): void => { this.loadCurrent() } })
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
        .accessibilityText(`长按拖动，${node.title}`)
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
  inputPanel() {
    Column({ space: 12 }) {
      TextInput({ text: this.titleInput, placeholder: this.initialKind === 'task' ? '任务标题' : '章节标题' })
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
      Text(this.initialKind === 'task' ? '添加任务' : '添加章节')
        .fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text).layoutWeight(1)
      OrgFileStructureAction({ title: '取消', available: !this.busy, action: (): void => { this.back() } })
      Button(this.busy ? '正在保存' : '保存')
        .id('project_structure_save').height(44).fontColor(UiColor.surface).backgroundColor(UiColor.primary)
        .enabled(!this.busy && !this.stale() && !!this.titleInput.trim()).onClick((): void => { this.applyForm() })
    }.width('100%')
  }

  private formLocation(): string {
    const location = this.draft?.path(this.parent) ?? this.source.title
    return `${location} › ${this.parent === null ? '顶层首位' : '子节点首位'}`
  }

  @Builder
  orderPanel() {
    Row() {
      Text('调整子节点顺序')
        .fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text).layoutWeight(1)
      OrgFileStructureAction({ title: this.busy ? '正在保存' : '完成', available: !this.busy, action: this.close })
    }.width('100%')
    Text(this.draft?.path(this.parent) ?? this.source.title).fontSize(14).fontColor(UiColor.secondary).width('100%')
    this.status()
    if (this.source.hasConflict) {
      Text('文件包含受保护的同步冲突').fontSize(13).fontColor(UiColor.secondary).width('100%').padding({top: 6, bottom: 6})
    }
    List({ scroller: this.orderScroller }) {
      ForEach(this.ordered, (node: OrgFileStructureNode) => {
        ListItem() {
          Stack({ alignContent: Alignment.Center }) {
            Row({ space: 10 }) {
              this.nodeIcon(node.task)
              TitleText({ text: node.title, parts: node.titleParts, textSize: 16, lineLimit: 1, openLinks: false }).layoutWeight(1)
              if (node.hidden) { Text('筛选隐藏').fontSize(12).fontColor(UiColor.secondary) }
              this.grip(node)
            }.width('100%').height(orderRowHeight)
              .backgroundColor(this.dragId === node.id ? UiColor.selectionTint : Color.Transparent)
            this.dropLine(node.id)
          }.width('100%').alignContent(this.dropBefore === node.id ? Alignment.Top : Alignment.Bottom)
        }
      }, (node: OrgFileStructureNode) => node.id)
    }.id('project_child_order_list').layoutWeight(1).width('100%').divider({ strokeWidth: 0.5, color: UiColor.outline })
      .enableScrollInteraction(this.dragId === '').enabled(!this.busy && !this.stale())
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
