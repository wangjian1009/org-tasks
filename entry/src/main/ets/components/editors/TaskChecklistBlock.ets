import { CoreTaskChecklistItem, CoreTaskChecklistChange } from '../../services/NativeCoreService'
import { checklistSiblings } from '../../ui/TaskChecklistReorder'
import { UiColor } from '../../ui/Theme'

// 只读与可写清单使用同一行结构；只读保留状态、行高、缩进和手柄占位。
@Component
export struct TaskChecklistBlock {
  @Prop items: CoreTaskChecklistItem[] = []
  @Prop readonly: boolean = false
  @Prop disabled: boolean = false
  @Prop editingId: string = ''
  @Prop editingText: string = ''
  @Prop adding: boolean = false
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
  scroller: ListScroller = new ListScroller()
  toggle: (change: CoreTaskChecklistChange) => void = () => {}
  edit: (item: CoreTaskChecklistItem) => void = () => {}
  editChanged: (text: string) => void = () => {}
  newChanged: (text: string) => void = () => {}
  save: (next: boolean) => void = () => {}
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

  @Builder
  row(item: CoreTaskChecklistItem, floating: boolean = false) {
    Row({ space: 4 }) {
      Button(item.checked ? '✓' : item.partial ? '−' : '○').width(28).height(44).padding(0)
        .fontSize(19).fontColor(UiColor.secondary).backgroundColor(Color.Transparent)
        .enabled(!this.disabled && !this.dragging && !floating).focusable(!this.readonly)
        .accessibilityText(this.readonly ? `${item.text}，${item.checked ? '已完成' : item.partial ? '部分完成' : '未完成'}` : item.checked ? `恢复未完成：${item.text}` : `完成：${item.text}`)
        .onClick((): void => { if (!this.readonly) this.toggle({ type: 'setChecked', id: item.id, checked: !item.checked }) })
      if (!this.readonly && !floating && this.editingId === item.id) {
        TextInput({ text: this.editingText }).id(`inline_check_${item.id}`).layoutWeight(1).fontSize(14)
          .fontColor(UiColor.text).backgroundColor(Color.Transparent).padding(0).enterKeyType(EnterKeyType.Next)
          .enabled(!this.disabled).onChange((text: string): void => { this.editChanged(text) })
          .onFocus((): void => { this.focused() }).onBlur((): void => { this.save(false) })
          .onAppear((): void => { this.inputAppeared(`inline_check_${item.id}`) })
          .onDisAppear((): void => { this.inputDisappeared(`inline_check_${item.id}`) })
          .onVisibleAreaChange([0, 1], (visible: boolean): void => { if (visible) this.inputVisible(`inline_check_${item.id}`) })
          .onSubmit((_key: EnterKeyType, event?: SubmitEvent): void => { event?.keepEditableState(); this.save(true) })
      } else {
        Text(item.text).layoutWeight(1).fontSize(14).fontColor(item.checked ? UiColor.disabled : UiColor.text)
          .decoration({ type: item.checked ? TextDecorationType.LineThrough : TextDecorationType.None })
          .onClick((): void => { if (!this.readonly && !this.disabled && !floating) this.edit(item) })
      }
      if (this.sorting && checklistSiblings(this.items, item.id).length > 1) {
        if (this.readonly) { Row().width(44).height(44).accessibilityLevel('no') }
        else { this.grip(item, floating) }
      }
    }.width('100%').constraintSize({ minHeight: 44 }).padding({ left: Math.min(item.depth, 6) * 12 })
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
        ForEach(this.items, (item: CoreTaskChecklistItem) => {
          ListItem() { this.row(item) }
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
        }, (item: CoreTaskChecklistItem): string => `${item.id}:${item.text}:${item.checked}:${item.partial}`)
        if (!this.readonly && this.adding) {
          ListItem() {
            Row({ space: 4 }) {
              Text('○').width(28).fontSize(19).fontColor(UiColor.secondary)
              TextInput({ text: this.newText, placeholder: '清单项' }).id(`inline_new_check_${this.ownerKey}`)
                .enabled(!this.disabled && !this.dragging).layoutWeight(1).fontSize(14).fontColor(UiColor.text)
                .backgroundColor(Color.Transparent).padding(0).enterKeyType(EnterKeyType.Next)
                .onFocus((): void => { this.focused() }).onChange((text: string): void => { this.newChanged(text) })
                .onBlur((): void => { this.save(false) })
                .onAppear((): void => { this.inputAppeared(`inline_new_check_${this.ownerKey}`) })
                .onDisAppear((): void => { this.inputDisappeared(`inline_new_check_${this.ownerKey}`) })
                .onVisibleAreaChange([0, 1], (visible: boolean): void => { if (visible) this.inputVisible(`inline_new_check_${this.ownerKey}`) })
                .onSubmit((_key: EnterKeyType, event?: SubmitEvent): void => { event?.keepEditableState(); this.save(true) })
            }.width('100%').height(44)
          }
        }
        if (!this.readonly && this.showAdd) {
          ListItem() {
            Text('+  添加清单项').fontSize(14).fontColor(UiColor.secondary).width('100%').height(44)
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
        Column() { ForEach(this.dragItems, (item: CoreTaskChecklistItem) => { this.row(item, true) }, (item: CoreTaskChecklistItem): string => item.id) }
          .width('100%').height(this.dragHeight).backgroundColor('#494743').borderRadius(8)
          .shadow({ radius: 8, color: '#52000000', offsetY: 4 }).position({ x: 0, y: this.dragTop - 4 }).hitTestBehavior(HitTestMode.None)
      }
    }.id(`inline_checks_${this.ownerKey}_${this.blockId}`).width('100%').height(this.rowHeight(this.measuredHeight))
  }
}
