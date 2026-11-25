import { CoreTaskChecklistItem, CoreTaskChecklistChange, CoreContentNode, CoreContentBlockChange } from '../../services/NativeCoreService'
import { checklistBlockEnd, checklistSiblings } from '../../ui/TaskChecklistReorder'
import { UiColor, UiSize } from '../../ui/Theme'
import { TaskNativeContent } from './TaskNativeContent'
import { TaskBlockController } from '../../ui/TaskBlockController'
import { LinkEditController } from '../LinkView'
import { InternalLinkProcessor } from '../../ui/InternalLinkProcessor'
import { FrameCallback } from '@ohos.arkui.UIContext'

export class ChecklistFocusFrame extends FrameCallback {
  private callback: () => void
  constructor(callback: () => void) { super(); this.callback = callback }
  onFrame(_frameTimeInNano: number): void {}
  onIdle(_timeLeftInNano: number): void { this.callback() }
}

// 只读与可写清单使用同一行结构；只读保留状态、行高、缩进和手柄占位。
@Component
export struct TaskChecklistBlock {
  @Prop items: CoreTaskChecklistItem[] = []
  @Prop readonly: boolean = false
  @Prop disabled: boolean = false
  @Prop editingId: string = ''
  @Prop editingText: string = ''
  @Prop adding: boolean = false
  @Prop addingAfter: string = ''
  @Prop newText: string = ''
  @Prop showAdd: boolean = false
  @Prop sorting: boolean = false
  @Prop ownerKey: string = ''
  @Prop blockId: string = ''
  @Prop listHeight: number = 0
  @Prop dragging: boolean = false
  @Prop dragTop: number = 0
  @Prop dragHeight: number = 0
  @Prop dragPlaceholder: number = 0
  @Prop dragValid: boolean = true
  @Prop dragItems: CoreTaskChecklistItem[] = []
  @Prop tree: CoreContentNode | undefined = undefined
  @Prop revision: string = ''
  processor: InternalLinkProcessor | undefined = undefined
  editor: TaskBlockController = new TaskBlockController()
  linkEditor: LinkEditController = new LinkEditController()
  beginNode: () => Promise<boolean> = async () => false
  writeNode: (change: CoreContentBlockChange) => Promise<void> = async () => {}
  editingChanged: (editing: boolean) => void = () => {}
  linkEditingChanged: (editing: boolean) => void = () => {}
  scroller: ListScroller = new ListScroller()
  toggle: (change: CoreTaskChecklistChange) => void = () => {}
  edit: (item: CoreTaskChecklistItem) => void = () => {}
  editChanged: (text: string) => void = () => {}
  newChanged: (text: string) => void = () => {}
  save: (next: boolean, id: string) => void = () => {}
  remove: (item: CoreTaskChecklistItem) => void = () => {}
  add: () => void = () => {}
  focused: () => void = () => {}
  inputAppeared: (id: string) => void = () => {}
  inputDisappeared: (id: string) => void = () => {}
  inputVisible: (id: string) => void = () => {}
  measured: (item: CoreTaskChecklistItem, area: Area) => void = () => {}
  touchChanged: (touching: boolean) => void = () => {}
  @BuilderParam grip: (item: CoreTaskChecklistItem, floating: boolean) => void = this.emptyGrip
  @State measuredHeight: number = 0
  private heights: Map<string, number> = new Map()

  @Builder
  emptyGrip(_item: CoreTaskChecklistItem, _floating: boolean) {}

  rowHeight(_revision: number): number {
    if (this.listHeight > 0) return this.listHeight
    return this.items.reduce((sum: number, item: CoreTaskChecklistItem): number => sum + (this.heights.get(item.id) ?? 44), 0)
      + (!this.readonly && this.adding ? 44 : 0) + (!this.readonly && this.showAdd ? 44 : 0)
  }

  private rows(): CoreTaskChecklistItem[] {
    if (this.readonly || !this.adding) return this.items
    const after = this.items.findIndex(item => item.id === this.addingAfter)
    const position = after < 0 ? this.items.length : checklistBlockEnd(this.items, after)
    const draft: CoreTaskChecklistItem = {
      id: '', text: '', checked: false, partial: false, depth: this.items[after]?.depth ?? 0, siblingGroup: ''
    }
    return this.items.slice(0, position).concat([draft], this.items.slice(position))
  }

  @Builder
  draftRow(depth: number) {
    Row({ space: UiSize.listMarkerGap }) {
      Text(this.marker(this.addingAfter) ?? '○').width(UiSize.listMarkerWidth).fontSize(19).fontColor(UiColor.secondary)
      TextInput({ text: this.newText, placeholder: '条目' }).id(`inline_new_check_${this.ownerKey}`)
        .enabled(!this.disabled && !this.dragging).layoutWeight(1).fontSize(UiSize.listItemFont).fontColor(UiColor.text)
        .backgroundColor(Color.Transparent).padding(0).enterKeyType(EnterKeyType.Next)
        .onFocus((): void => { this.focused() }).onChange((text: string): void => { this.newChanged(text) })
        .onBlur((): void => { this.save(false, '') })
        .onAppear((): void => { this.inputAppeared(`inline_new_check_${this.ownerKey}`) })
        .onDisAppear((): void => { this.inputDisappeared(`inline_new_check_${this.ownerKey}`) })
        .onVisibleAreaChange([0, 1], (visible: boolean): void => { if (visible) this.inputVisible(`inline_new_check_${this.ownerKey}`) })
        .onSubmit((_key: EnterKeyType, event?: SubmitEvent): void => { event?.keepEditableState(); this.save(true, '') })
    }.width('100%').height(44).padding({ left: Math.min(depth, 6) * UiSize.listIndent })
  }

  // 现有排序使用平铺行的测量值。续段按原次序绑定到上一个可见清单行。
  private projectedItem(nodes: CoreContentNode[], id: string): CoreContentNode | undefined {
    for (const node of nodes) {
      if (node.kind === 'item' && node.id === id) return node
      const entry = this.projectedItem(node.children ?? [], id)
      if (entry) return entry
    }
    return undefined
  }

  private projectedBody(id: string): CoreContentNode[] {
    const item = this.projectedItem(this.tree?.children ?? [], id)
    const children = item?.children ?? []
    const at = children.findIndex((child: CoreContentNode): boolean => child.kind === 'list')
    return at === -1 ? children : children.slice(0, at)
  }

  private marker(id: string): string | undefined {
    const node = this.projectedItem(this.tree?.children ?? [], id)
    return node && !node.checkbox ? node.marker ?? '•' : undefined
  }

  private continuations(nodes: CoreContentNode[], id: string): CoreContentNode[] {
    const result: CoreContentNode[] = []
    for (const item of nodes) {
      let after = ''
      for (const child of item.children ?? []) {
        if (child.kind === 'list') {
          result.push(...this.continuations(child.children ?? [], id))
          after = this.lastItem(child)
        } else if (after === id) {
          result.push(child)
        }
      }
    }
    return result
  }

  private lastItem(list: CoreContentNode): string {
    const items = list.children ?? []
    const item = items[items.length - 1]
    if (!item) return ''
    const children = item.children ?? []
    for (let index = children.length - 1; index >= 0; index--) {
      if (children[index].kind === 'list') return this.lastItem(children[index]) || item.id
    }
    return item.id
  }

  @Builder
  row(item: CoreTaskChecklistItem, floating: boolean = false) {
    Row({ space: UiSize.listMarkerGap }) {
      if (this.marker(item.id) !== undefined) {
        Text(this.marker(item.id)).width(UiSize.listMarkerWidth).height(44).padding({ top: 11 })
          .fontSize(UiSize.listItemFont).lineHeight(UiSize.listItemLineHeight).fontColor(UiColor.secondary)
      } else {
        Button(item.checked ? '✓' : item.partial ? '−' : '○').width(UiSize.listMarkerWidth).height(44).padding(0)
          .fontSize(19).fontColor(UiColor.secondary).backgroundColor(Color.Transparent)
          .enabled(!this.disabled && !this.dragging && !floating).focusable(!this.readonly)
          .accessibilityText(this.readonly ? `${item.text}，${item.checked ? '已完成' : item.partial ? '部分完成' : '未完成'}` : item.checked ? `恢复未完成：${item.text}` : `完成：${item.text}`)
          .onClick((): void => { if (!this.readonly) this.toggle({ type: 'setChecked', id: item.id, checked: !item.checked }) })
      }
      if (!this.readonly && !floating && this.editingId === item.id) {
        TextInput({ text: this.editingText }).id(`inline_check_${item.id}`).layoutWeight(1).fontSize(UiSize.listItemFont)
          .fontColor(UiColor.text).backgroundColor(Color.Transparent).padding(0).enterKeyType(EnterKeyType.Next)
          .enabled(!this.disabled).onChange((text: string): void => { this.editChanged(text) })
          .onFocus((): void => { this.focused() }).onBlur((): void => { this.save(false, item.id) })
          .onAppear((): void => { this.inputAppeared(`inline_check_${item.id}`) })
          .onDisAppear((): void => { this.inputDisappeared(`inline_check_${item.id}`) })
          .onVisibleAreaChange([0, 1], (visible: boolean): void => { if (visible) this.inputVisible(`inline_check_${item.id}`) })
          .onSubmit((_key: EnterKeyType, event?: SubmitEvent): void => { event?.keepEditableState(); this.save(true, item.id) })
      } else if (this.projectedBody(item.id).length > 0) {
        TaskNativeContent({ nodes: this.projectedBody(item.id), itemId: item.id, activateParagraph: (): void => { this.edit(item) }, completed: item.checked,
          readonly: this.readonly || floating, disabled: this.disabled || this.dragging, revision: this.revision,
          processor: this.processor, editor: this.editor, linkEditor: this.linkEditor,
          begin: this.beginNode, write: this.writeNode, editingChanged: this.editingChanged,
          linkEditingChanged: this.linkEditingChanged }).layoutWeight(1).padding({ top: 11, bottom: 11 })
      } else {
        Text(item.text).layoutWeight(1).fontSize(UiSize.listItemFont).lineHeight(UiSize.listItemLineHeight).fontColor(item.checked ? UiColor.disabled : UiColor.text)
          .decoration({ type: item.checked ? TextDecorationType.LineThrough : TextDecorationType.None })
          .onClick((): void => { if (!this.readonly && !this.disabled && !floating) this.edit(item) })
      }
      if (this.sorting && checklistSiblings(this.items, item.id).length > 1) {
        if (this.readonly) { Row().width(44).height(44).accessibilityLevel('no') }
        else { this.grip(item, floating) }
      }
    }.width('100%').constraintSize({ minHeight: 44 })
      .alignItems(this.projectedBody(item.id).length > 0 ? VerticalAlign.Top : VerticalAlign.Center)
      .padding({ left: Math.min(item.depth, 6) * UiSize.listIndent })
  }

  @Builder
  deleteItem(item: CoreTaskChecklistItem) {
    Button({ type: ButtonType.Circle }) { Image($r('app.media.ui_delete')).width(24).height(24) }
      .width(44).height(44).padding(0).backgroundColor('#513A40')
      .enabled(!this.readonly && !this.disabled && !this.dragging).accessibilityText(`删除清单条目：${item.text}`)
      .onClick((): void => { if (!this.readonly) this.remove(item) })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      List({ scroller: this.scroller }) {
        ForEach(this.rows(), (item: CoreTaskChecklistItem) => {
          if (item.id === '') {
            ListItem() { this.draftRow(item.depth) }
          } else {
            ListItem() {
              Column() {
                this.row(item)
                this.continuedBody(item, false)
              }.width('100%')
            }
              .opacity(this.dragging && this.dragItems.some((moving: CoreTaskChecklistItem): boolean => moving.id === item.id) ? 0 : 1)
              .onAreaChange((_old: Area, area: Area): void => {
                const height = Math.max(44, parseFloat(area.height.toString()))
                if (!this.dragging && Math.abs((this.heights.get(item.id) ?? 0) - height) > 0.5) {
                  this.heights.set(item.id, height); this.measuredHeight++
                }
                this.measured(item, area)
              })
              .onTouch((event: TouchEvent): void => {
                if (event.type === TouchType.Down) this.touchChanged(true)
                if (event.type === TouchType.Up || event.type === TouchType.Cancel) setTimeout((): void => { this.touchChanged(false) }, 100)
              })
              .swipeAction(this.readonly || this.dragging || this.disabled ? {} : { end: this.deleteItem(item), edgeEffect: SwipeEdgeEffect.None })
          }
        }, (item: CoreTaskChecklistItem): string => `${item.id}:${item.text}:${item.checked}:${item.partial}:${item.depth}`)
        if (!this.readonly && this.showAdd) {
          ListItem() {
            Text(this.marker(this.items[0]?.id ?? '') === undefined ? '+  添加清单项' : '+  添加条目')
              .fontSize(14).fontColor(UiColor.secondary).width('100%').height(44)
              .enabled(!this.disabled && !this.dragging).onClick((): void => { this.add() })
          }
        }
      }.width('100%').height(this.rowHeight(this.measuredHeight)).scrollBar(BarState.Off).enableScrollInteraction(false)
      if (this.dragging) {
        Column().width('100%').height(this.dragHeight).backgroundColor('#303330').borderRadius(8)
          .position({ x: 0, y: this.dragPlaceholder }).hitTestBehavior(HitTestMode.None)
        if (this.dragValid) {
          Rect().width('100%').height(2).fill(UiColor.primary).position({ x: 0, y: this.dragPlaceholder }).hitTestBehavior(HitTestMode.None)
        }
        Column() {
          ForEach(this.dragItems, (item: CoreTaskChecklistItem) => {
            Column() {
              this.row(item, true)
              this.continuedBody(item, true)
            }.width('100%')
          }, (item: CoreTaskChecklistItem): string => item.id)
        }
          .width('100%').height(this.dragHeight).backgroundColor('#494743').borderRadius(8)
          .shadow({ radius: 8, color: '#52000000', offsetY: 4 }).position({ x: 0, y: this.dragTop - 4 }).hitTestBehavior(HitTestMode.None)
      }
    }.id(`inline_checks_${this.ownerKey}_${this.blockId}`).width('100%').height(this.rowHeight(this.measuredHeight))
  }

  @Builder
  continuedBody(item: CoreTaskChecklistItem, floating: boolean) {
    if (this.continuations(this.tree?.children ?? [], item.id).length > 0) {
      TaskNativeContent({ nodes: this.continuations(this.tree?.children ?? [], item.id),
        readonly: this.readonly || floating, disabled: this.disabled || this.dragging, revision: this.revision,
        processor: this.processor, editor: this.editor, linkEditor: this.linkEditor,
        begin: this.beginNode, write: this.writeNode, editingChanged: this.editingChanged,
        linkEditingChanged: this.linkEditingChanged }).padding({ left: UiSize.listMarkerWidth + UiSize.listMarkerGap + Math.min(item.depth, 6) * UiSize.listIndent })
    }
  }
}
