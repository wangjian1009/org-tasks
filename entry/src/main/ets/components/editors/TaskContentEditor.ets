import { TaskContentSlot, contentDragScrollSpeed, reconcileTaskContent, taskContentGap } from '../../ui/TaskContentPresentation'
import { InternalLinkProcessor } from '../../ui/InternalLinkProcessor'
import { CoreContentBlock, CoreTextLink, CoreLinkValue, CoreContentNode, CoreContentBlockChange, CoreTaskChecklistChange } from '../../services/NativeCoreService'
import { ChecklistFocusFrame, TaskChecklistBlock } from './TaskChecklistBlock'
import { TaskNativeContent } from './TaskNativeContent'
import { TaskBlockView } from './TaskBlockView'
import { TaskBlockController } from '../../ui/TaskBlockController'
import { LinkEditController } from '../LinkView'
import { UiColor, UiSize } from '../../ui/Theme'

@Component
export struct TaskContentEditor {
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop @Watch('contentChanged') blocks: CoreContentBlock[] = []
  @State private slots: TaskContentSlot[] = []
  @State private movingId: string = ''
  @State private savingMove: boolean = false
  @State private dragSlot: string = ''
  @State private dragOffset: number = 0
  @State private dragTarget: number = -1
  @State private dragHeight: number = 0
  @Prop @Watch('moveContextChanged') moveVersion: string = ''
  @Prop contentTree: CoreContentNode[] | undefined = undefined
  @State private followKey: string = ''
  @State private followRequest: number = 0
  beginEmpty: () => Promise<boolean> = async () => false
  @Prop showEmptyPrompt: boolean = true
  @Prop addMenuRequest: number = 0
  addMenuOpened: () => void = () => {}
  saveFirstChecklist: (text: string) => Promise<boolean> = async () => false
  writeNode: (change: CoreContentBlockChange) => Promise<void> = async () => {}
  addChecklistItem: (after: string) => void = () => {}
  toggle: (change: CoreTaskChecklistChange) => void = () => {}
  @Prop @Watch('moveContextChanged') readonly: boolean = false
  @Prop horizontalParentFirst: boolean = true
  @Prop checklistEditing: boolean = false
  @Prop @Watch('moveContextChanged') disabled: boolean = false
  @Prop revision: string = ''
  @Prop contentBackground: string = UiColor.taskCard
  @Prop ownerKey: string = ''
  scrollHost: Scroller | undefined = undefined
  scrollHostId: string = ''
  editor: TaskBlockController = new TaskBlockController()
  linkEditor: LinkEditController = new LinkEditController()
  begin: (block: CoreContentBlock) => Promise<boolean> = async () => true
  save: (block: CoreContentBlock, source: string) => Promise<boolean> = async () => false
  moveContent: ((id: string, beforeId: string | null, version: string) => Promise<boolean>) | undefined = undefined
  moveEnded: () => void = () => {}
  changeLink: ((block: CoreContentBlock, link: CoreTextLink, value: CoreLinkValue | null) => Promise<void>) | undefined = undefined
  editingChanged: (editing: boolean) => void = () => {}
  linkEditingChanged: (editing: boolean) => void = () => {}
  @BuilderParam checklist: (index: () => number) => void = this.readChecklist

  private moveOwner: string = ''
  private selectedVersion: string = ''
  private active: boolean = false
  private dragGrabY: number = 0
  private dragX: number = 0
  private dragY: number = 0
  private dragScrollTimer: number = -1
  private lastDragScroll: number = 0
  private handledAddMenu: number = 0
  private emptyBlock: CoreContentBlock = { id: 'root', kind: 'text', paragraph: true, blankLinesBefore: 0, source: '', html: '', items: [] }

  aboutToAppear(): void {
    this.active = true
    this.moveOwner = `content_move_${this.getUniqueId()}`
    this.contentChanged()
  }

  aboutToDisappear(): void {
    this.active = false
    this.cancelMove()
  }

  contentChanged(): void {
    const next = reconcileTaskContent(this.slots, this.blocks)
    if (next !== this.slots) this.slots = next
    if (this.movingId && !this.savingMove && !this.blocks.some(block => block.id === this.movingId)) this.cancelMove()
  }

  moveContextChanged(): void {
    if (!this.movingId || this.savingMove) return
    if (this.selectedVersion !== this.moveVersion) {
      this.cancelMove()
      try { this.getUIContext().getPromptAction().showToast({ message: '正文已变化，请重新选择移动位置' }) }
      catch (_) { /* 宿主离开时可能没有可用窗口。 */ }
    } else if (this.readonly || this.disabled) {
      this.cancelMove()
    }
  }

  private async selectMove(block: CoreContentBlock): Promise<void> {
    const version = this.moveVersion
    if (!this.active || !version || this.readonly || this.disabled || this.movingId) return
    if (!await this.editor.begin(this.moveOwner, async (): Promise<boolean> => {
      if (this.savingMove) return false
      this.cancelMove()
      return true
    }, (): void => { this.cancelMove() })) return
    if (!this.active || version !== this.moveVersion || this.readonly || this.disabled) {
      this.cancelMove()
      return
    }
    this.selectedVersion = version
    this.movingId = block.id
  }

  private cancelMove(): void {
    const wasMoving = this.movingId !== ''
    this.resetDrag()
    this.movingId = ''
    this.selectedVersion = ''
    this.editor.release(this.moveOwner)
    if (wasMoving) this.moveEnded()
  }

  private canDragBlock(slot: TaskContentSlot): boolean {
    return this.selectedForMove(slot) && !this.disabled && !this.readonly && !this.savingMove
  }

  private selectedForMove(slot: TaskContentSlot): boolean {
    return this.movingId !== '' && this.blockFor(slot).id === this.movingId
  }

  private resetDrag(): void {
    if (this.dragScrollTimer >= 0) clearInterval(this.dragScrollTimer)
    this.dragScrollTimer = -1
    this.dragSlot = ''
    this.dragOffset = 0
    this.dragTarget = -1
    this.dragHeight = 0
  }

  private startBlockDrag(slot: TaskContentSlot, event: GestureEvent): void {
    const finger = event.fingerList[0]
    const context = this.getUIContext()
    const node = context.getFrameNodeById(`${this.moveOwner}_${slot.key}`)
    if (!finger || !node || !this.canDragBlock(slot)) return
    this.dragGrabY = finger.globalY - event.offsetY - node.getPositionToWindow().y
    this.dragHeight = context.px2vp(node.getMeasuredSize().height)
    this.dragSlot = slot.key
    this.updateBlockDrag(event)
    if (this.dragSlot) {
      this.lastDragScroll = Date.now()
      this.dragScrollTimer = setInterval((): void => { this.scrollBlockDrag() }, 16)
    }
  }

  private updateBlockDrag(event?: GestureEvent): void {
    if (!this.dragSlot) return
    const finger = event?.fingerList[0]
    if (finger) {
      this.dragX = finger.globalX
      this.dragY = finger.globalY
    }
    const context = this.getUIContext()
    const node = context.getFrameNodeById(`${this.moveOwner}_${this.dragSlot}`)
    if (!node) { this.resetDrag(); return }
    this.dragOffset = this.dragY - node.getPositionToWindow().y - this.dragGrabY
    const target = this.blockDropTarget()
    if (target !== this.dragTarget) {
      context.animateTo({ duration: 140, curve: Curve.EaseOut }, (): void => { this.dragTarget = target })
    }
  }

  private blockDropTarget(): number {
    const context = this.getUIContext()
    const host = this.scrollHostId ? context.getFrameNodeById(this.scrollHostId) : null
    if (host) {
      const top = host.getPositionToWindow().y
      if (this.dragY < top || this.dragY > top + context.px2vp(host.getMeasuredSize().height)) return -1
    }
    for (let index = 0; index <= this.blocks.length; index++) {
      if (!this.validMoveGap(index)) continue
      const gap = context.getFrameNodeById(this.moveGapId(index))
      if (!gap) continue
      const position = gap.getPositionToWindow()
      const size = gap.getMeasuredSize()
      const height = context.px2vp(size.height)
      // 收拢时仍保留足够的命中范围。展开后按实际高度接收松手。
      const padding = Math.max(0, (44 - height) / 2)
      if (this.dragX >= position.x && this.dragX <= position.x + context.px2vp(size.width) &&
        this.dragY >= position.y - padding && this.dragY <= position.y + height + padding) {
        return index
      }
    }
    return -1
  }

  private scrollBlockDrag(): void {
    if (!this.dragSlot) return
    const now = Date.now()
    const elapsed = Math.min(32, now - this.lastDragScroll) / 1000
    this.lastDragScroll = now
    const context = this.getUIContext()
    const host = this.scrollHostId ? context.getFrameNodeById(this.scrollHostId) : null
    if (host && this.scrollHost) {
      const top = host.getPositionToWindow().y
      const bottom = top + context.px2vp(host.getMeasuredSize().height)
      const speed = contentDragScrollSpeed(this.dragY, top, bottom)
      if (speed) {
        const direction = Math.sign(speed)
        const edgeLimit = this.contentScrollLimit(direction, speed < 0 ? top + 48 : bottom - 48)
        const distance = Math.min(Math.abs(speed * elapsed), edgeLimit)
        if (distance > 0) this.scrollHost.scrollBy(0, direction * distance)
      }
    }
    // 占位展开会改变源区块的位置，即使手指暂时停住也需要重新计算跟手偏移。
    this.updateBlockDrag()
  }

  private contentScrollLimit(direction: number, edge: number): number {
    const context = this.getUIContext()
    const first = this.blocks.findIndex(block => block.id === this.movingId) === 0 ? 2 : 0
    const last = this.blocks[this.blocks.length - 1]?.id === this.movingId ? this.blocks.length - 2 : this.blocks.length
    const gap = context.getFrameNodeById(this.moveGapId(direction < 0 ? first : last))
    if (!gap) return Infinity
    const center = gap.getPositionToWindow().y + context.px2vp(gap.getMeasuredSize().height) / 2
    return Math.max(0, direction * (center - edge))
  }

  private finishBlockDrag(event: GestureEvent): void {
    if (!this.dragSlot) return
    this.updateBlockDrag(event)
    const target = this.blockDropTarget()
    if (target < 0) {
      this.resetDrag()
      return
    }
    if (this.dragScrollTimer >= 0) clearInterval(this.dragScrollTimer)
    this.dragScrollTimer = -1
    this.placeBlock(this.blocks[target]?.id ?? null)
  }

  private async followSavedBlock(key: string, finish: () => Promise<boolean>,
    follow: (anchor: TaskContentSlot, index: number) => void): Promise<void> {
    const index = key ? this.indexFor(key) : -1
    if (key && index < 0) return
    const following = key ? this.slots[index + 1]?.key : undefined
    if (!await finish() || !this.active) return
    this.getUIContext().postFrameCallback(new ChecklistFocusFrame((): void => {
      if (!this.active || this.readonly || this.disabled) return
      const position = following ? this.indexFor(following) : this.slots.length
      const anchor = this.slots[position - 1]
      if (!anchor || (key && position <= index)) return
      follow(anchor, position - 1)
    }))
  }

  private async appendFollowingParagraph(key: string, finish: () => Promise<boolean>): Promise<void> {
    await this.followSavedBlock(key, finish, (anchor: TaskContentSlot): void => {
      this.followKey = anchor.key
      this.followRequest++
    })
  }

  private async appendFollowingChecklistItem(key: string, finish: () => Promise<boolean>): Promise<void> {
    const index = this.indexFor(key)
    await this.followSavedBlock(key, finish, (anchor: TaskContentSlot, savedIndex: number): void => {
      if (savedIndex <= index || anchor.block.kind !== 'checklist') return
      const item = anchor.block.items[0]
      if (item) this.addChecklistItem(item.id)
    })
  }

  private async saveFirstParagraph(source: string): Promise<boolean> {
    if (!source.trim()) return true
    try {
      await this.writeNode({ type: 'insertParagraph', id: 'root', source })
      return true
    } catch (_) { return false }
  }

  private openAddMenu(request: number, y: number): boolean {
    if (request === this.handledAddMenu || request !== this.addMenuRequest) return false
    this.handledAddMenu = request
    const host = this.scrollHostId ? this.getUIContext().getFrameNodeById(this.scrollHostId) : null
    if (host && this.scrollHost) {
      const bottom = host.getPositionToWindow().y + this.getUIContext().px2vp(host.getMeasuredSize().height)
      if (y > bottom - 60) this.scrollHost.scrollBy(0, y - bottom + 60)
    }
    this.addMenuOpened()
    return true
  }

  private addMenuFor(slot: TaskContentSlot): number {
    return this.slots[this.slots.length - 1]?.key === slot.key ? this.addMenuRequest : 0
  }

  private validMoveGap(index: number): boolean {
    return !!this.movingId && index >= 0 && index <= this.blocks.length &&
      this.blocks[index]?.id !== this.movingId && this.blocks[index - 1]?.id !== this.movingId
  }

  private moveGapId(index: number): string {
    return `${this.moveOwner}_gap_${index}`
  }

  private async placeBlock(beforeId: string | null): Promise<void> {
    if (!this.movingId || this.savingMove || this.disabled || this.selectedVersion !== this.moveVersion || !this.moveContent) return
    const index = beforeId === null ? this.blocks.length : this.blocks.findIndex(block => block.id === beforeId)
    if (!this.validMoveGap(index)) return
    this.savingMove = true
    try {
      await this.moveContent(this.movingId, beforeId, this.selectedVersion)
    } finally {
      this.savingMove = false
      this.cancelMove()
    }
  }

  @Builder
  moveGap(index: number, beforeId: string | null) {
    Button({ type: ButtonType.Normal }) {
      if (this.dragTarget === index) {
        Text('放入').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiColor.secondary)
      } else if (!this.dragSlot) {
        Circle({ width: 6, height: 6 }).fill(UiColor.projectLabel)
      }
    }.width('100%').height(this.dragTarget === index ? Math.max(52, this.dragHeight) : 16).padding(0).borderRadius(8)
      .backgroundColor(this.dragTarget === index ? UiColor.projectOutline : Color.Transparent)
      .responseRegion({ x: 0, y: -8, width: '100%', height: this.dragTarget === index ? Math.max(52, this.dragHeight) + 16 : 32 })
      .enabled(!this.savingMove && !this.disabled)
      .id(this.moveGapId(index))
      .accessibilityText(beforeId === null ? '移到正文末尾' : `移到区块之前：${this.blocks.find(block => block.id === beforeId)?.source.split('\n', 1)[0] ?? ''}`)
      .onClick((): void => { this.placeBlock(beforeId) })
  }

  blockFor(slot: TaskContentSlot): CoreContentBlock {
    // 删除时 ArkUI 可能在卸载旧行前再刷新一次其属性。
    return this.slots.find(current => current.key === slot.key)?.block ?? slot.block
  }
  indexFor(key: string): number { return this.slots.findIndex(slot => slot.key === key) }

  @Builder
  readChecklist(index: () => number) {
    TaskChecklistBlock({ items: this.blocks[index()].items, readonly: this.readonly, ownerKey: this.ownerKey, blockId: this.blocks[index()].id,
      tree: this.treeFor(this.blocks[index()].id), processor: this.internalLinkProcessor, revision: this.revision }).width('100%')
  }

  treeFor(id: string): CoreContentNode | undefined { return this.contentTree?.find(node => node.id === id) }

  @Builder
  nativeBlock(slot: TaskContentSlot, edit: () => void) {
    TaskNativeContent({ nodes: this.contentTree?.filter(node => node.id === this.blockFor(slot).id) ?? [], readonly: this.readonly, disabled: this.disabled,
      revision: this.revision, processor: this.internalLinkProcessor, editor: this.editor, linkEditor: this.linkEditor,
      activateParagraph: this.blockFor(slot).paragraph ? edit : undefined,
      begin: (): Promise<boolean> => this.begin(this.blockFor(slot)), write: this.writeNode, toggle: this.toggle,
      editingChanged: this.editingChanged, linkEditingChanged: this.linkEditingChanged })
  }

  build() {
    Column() {
      if (this.movingId) {
        Row({ space: 8 }) {
          Text(this.savingMove ? '正在移动…' : '拖到目标位置，或点按圆点').fontSize(14).fontColor(UiColor.text).layoutWeight(1)
          Button('取消').height(44).fontSize(14).backgroundColor(Color.Transparent).fontColor(UiColor.primary)
            .enabled(!this.savingMove).onClick((): void => { this.cancelMove() })
        }.width('100%')
      }
      if (!this.readonly && this.blocks.length === 0) {
        TaskBlockView({ block: this.emptyBlock, emptyBody: true, placeholder: '段落', disabled: this.disabled,
          showEmptyPrompt: this.showEmptyPrompt, addMenuRequest: this.addMenuRequest,
          openAddMenu: (request: number, y: number): boolean => this.openAddMenu(request, y),
          saveFirstChecklist: this.saveFirstChecklist,
          revision: this.revision, ownerKey: this.ownerKey, editor: this.editor, linkEditor: this.linkEditor,
          begin: (_block: CoreContentBlock): Promise<boolean> => this.beginEmpty(),
          save: (_block: CoreContentBlock, source: string): Promise<boolean> => this.saveFirstParagraph(source),
          followParagraph: (finish: () => Promise<boolean>): Promise<void> => this.appendFollowingParagraph('', finish),
          followChecklist: (finish: () => Promise<boolean>): Promise<void> => this.appendFollowingChecklistItem('', finish),
          editingChanged: this.editingChanged }).width('100%')
      }
      ForEach(this.slots, (slot: TaskContentSlot) => {
        if (this.validMoveGap(this.indexFor(slot.key))) { this.moveGap(this.indexFor(slot.key), this.blockFor(slot).id) }
        Column() {
          Row({ space: 8 }) {
            Column() {
              if (this.blockFor(slot).kind === 'checklist' ||
                (this.blockFor(slot).kind === 'list' && this.blockFor(slot).items.length > 0 &&
                  this.treeFor(this.blockFor(slot).id))) {
                TaskBlockView({ internalLinkProcessor: this.internalLinkProcessor, block: this.blockFor(slot), readonly: this.readonly, disabled: this.disabled,
                  addMenuRequest: this.addMenuFor(slot), openAddMenu: (request: number, y: number): boolean => this.openAddMenu(request, y),
                  revision: this.revision, nativeChecklist: true, checklistEditing: this.checklistEditing,
                  contentBackground: this.contentBackground, ownerKey: this.ownerKey, editor: this.editor, linkEditor: this.linkEditor,
                  insertBelow: true, nextBlock: this.blocks[this.indexFor(slot.key) + 1],
                  allowMove: !!this.moveContent && !!this.moveVersion && this.blocks.length > 1,
                  move: (block: CoreContentBlock): Promise<void> => this.selectMove(block),
                  followRequest: this.followKey === slot.key ? this.followRequest : 0,
                  followParagraph: (finish: () => Promise<boolean>): Promise<void> => this.appendFollowingParagraph(slot.key, finish),
                  followChecklist: (finish: () => Promise<boolean>): Promise<void> => this.appendFollowingChecklistItem(slot.key, finish),
                  placeholder: '列表', readContent: (): void => { this.checklist((): number => this.indexFor(slot.key)) }, begin: this.begin, save: this.save,
                  editingChanged: this.editingChanged }).width('100%')
              } else if (this.treeFor(this.blockFor(slot).id)) {
                TaskBlockView({ block: this.blockFor(slot), readonly: this.readonly, disabled: this.disabled,
                  addMenuRequest: this.addMenuFor(slot), openAddMenu: (request: number, y: number): boolean => this.openAddMenu(request, y),
                  revision: this.revision, nativeChecklist: true, contentBackground: this.contentBackground, ownerKey: this.ownerKey,
                  insertBelow: this.blockFor(slot).paragraph || this.blockFor(slot).kind === 'list',
                  allowMove: !!this.moveContent && !!this.moveVersion && this.blocks.length > 1 &&
                    (this.blockFor(slot).paragraph || this.blockFor(slot).kind === 'list'),
                  move: (block: CoreContentBlock): Promise<void> => this.selectMove(block),
                  nextBlock: this.blocks[this.indexFor(slot.key) + 1],
                  followRequest: this.followKey === slot.key ? this.followRequest : 0,
                  followParagraph: (finish: () => Promise<boolean>): Promise<void> => this.appendFollowingParagraph(slot.key, finish),
                  followChecklist: (finish: () => Promise<boolean>): Promise<void> => this.appendFollowingChecklistItem(slot.key, finish),
                  placeholder: this.blockFor(slot).paragraph ? '段落' : '正文',
                  editor: this.editor, linkEditor: this.linkEditor, nativeContent: (edit: () => void): void => { this.nativeBlock(slot, edit) },
                  begin: this.begin, save: this.save, editingChanged: this.editingChanged }).width('100%')
              } else {
                TaskBlockView({ internalLinkProcessor: this.internalLinkProcessor, block: this.blockFor(slot), readonly: this.readonly, disabled: this.disabled, revision: this.revision, horizontalParentFirst: this.horizontalParentFirst,
                  addMenuRequest: this.addMenuFor(slot), openAddMenu: (request: number, y: number): boolean => this.openAddMenu(request, y),
                  contentBackground: this.contentBackground, ownerKey: this.ownerKey, editor: this.editor, linkEditor: this.linkEditor,
                  followRequest: this.followKey === slot.key ? this.followRequest : 0,
                  followParagraph: (finish: () => Promise<boolean>): Promise<void> => this.appendFollowingParagraph(slot.key, finish),
                  nextBlock: this.blocks[this.indexFor(slot.key) + 1],
                  placeholder: this.blockFor(slot).paragraph ? '段落' : '正文',
                  begin: this.begin, save: this.save, changeLink: this.changeLink, editingChanged: this.editingChanged,
                  linkEditingChanged: this.linkEditingChanged }).width('100%')
              }
            }.layoutWeight(1).enabled(!this.movingId)
            if (this.canDragBlock(slot)) {
              Image($r('app.media.ui_drag_handle')).width(20).height(20).fillColor(UiColor.secondary)
                .draggable(false).accessibilityText(this.blockFor(slot).paragraph ? '拖动段落' : '拖动列表')
                .alignSelf(ItemAlign.Start).margin({ top: 12 })
            }
          }.width('100%').constraintSize({ minHeight: this.canDragBlock(slot) ? 44 : 0 })
            .padding({ left: this.selectedForMove(slot) ? 10 : 0, right: this.selectedForMove(slot) ? 10 : 0 })
            .backgroundColor(this.selectedForMove(slot) ? UiColor.menu : Color.Transparent).borderRadius(UiSize.contentLiftRadius)
            .shadow({ radius: UiSize.contentLiftShadowRadius, offsetY: UiSize.contentLiftShadowOffset,
              color: this.selectedForMove(slot) ? UiColor.contentLiftShadow : '#00000000' })
            .translate({ y: this.dragSlot === slot.key ? this.dragOffset : 0 })
        }.width('100%').id(`${this.moveOwner}_${slot.key}`).zIndex(this.selectedForMove(slot) ? 1 : 0)
          // 拖动时用负间距腾出原位置，保留区块原有的高度和手势节点。
          .margin({ top: this.movingId ? 0 : taskContentGap(this.blocks, this.indexFor(slot.key)),
            bottom: this.dragSlot === slot.key ? -this.dragHeight : 0 })
          .priorityGesture(PanGesture({ direction: PanDirection.All, distance: 4 }).tag('content_block_drag')
            .onActionStart((event: GestureEvent): void => { this.startBlockDrag(slot, event) })
            .onActionUpdate((event: GestureEvent): void => { this.updateBlockDrag(event) })
            .onActionEnd((event: GestureEvent): void => { this.finishBlockDrag(event) })
            .onActionCancel((): void => { this.resetDrag() }))
          .onGestureJudgeBegin((info: GestureInfo): GestureJudgeResult =>
            info.tag === 'content_block_drag' && !this.canDragBlock(slot) ? GestureJudgeResult.REJECT : GestureJudgeResult.CONTINUE)
      }, (slot: TaskContentSlot): string => slot.key)
      if (this.validMoveGap(this.blocks.length)) { this.moveGap(this.blocks.length, null) }
    }.width('100%')
  }
}
