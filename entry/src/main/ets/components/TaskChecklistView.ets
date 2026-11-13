import { CoreTaskChecklistChange, CoreTaskChecklistItem } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'

// 任务正文中的 checkbox 列表。任务卡和项目文档共用这一层，写入仍由宿主通过回调交给 Core。
@Component
export struct TaskChecklistView {
  @Prop items: CoreTaskChecklistItem[] = []
  @Prop editable: boolean = false
  @Prop working: boolean = false
  @Prop snapshotBlocked: boolean = false
  @Prop editingId: string = ''
  @Prop editingText: string = ''
  @Prop adding: boolean = false
  @Prop newText: string = ''
  @Prop showAdd: boolean = false
  toggle: (change: CoreTaskChecklistChange) => void = () => {}
  edit: (item: CoreTaskChecklistItem) => void = () => {}
  editChanged: (text: string) => void = () => {}
  editBlur: () => void = () => {}
  editSubmit: () => void = () => {}
  remove: (item: CoreTaskChecklistItem) => void = () => {}
  add: () => void = () => {}
  newChanged: (text: string) => void = () => {}
  newBlur: () => void = () => {}
  newSubmit: () => void = () => {}
  focused: () => void = () => {}
  inputAppeared: (id: string) => void = () => {}
  inputDisappeared: (id: string) => void = () => {}
  inputVisible: (id: string) => void = () => {}
  ownerKey: string = ''

  disabled(): boolean {
    return this.working || this.snapshotBlocked
  }

  @Builder
  row(item: CoreTaskChecklistItem) {
    Row({ space: 4 }) {
      Button(item.checked ? '✓' : item.partial ? '−' : '○').width(28).height(44).padding(0)
        .fontSize(19).fontColor(UiColor.secondary).backgroundColor(Color.Transparent)
        .enabled(this.editable && !this.disabled())
        .accessibilityText(item.checked ? `恢复未完成：${item.text}` : `完成：${item.text}`)
        .onClick(() => { this.toggle({ type: 'setChecked', id: item.id, checked: !item.checked }) })
      if (this.editable && this.editingId === item.id) {
        TextInput({ text: this.editingText }).id(`inline_check_${item.id}`).layoutWeight(1).fontSize(14)
          .fontColor(UiColor.text).backgroundColor(Color.Transparent).padding(0).enterKeyType(EnterKeyType.Next)
          .enabled(!this.disabled()).onChange((text: string) => { this.editChanged(text) })
          .onFocus(() => { this.focused() }).onBlur(() => { this.editBlur() })
          .onAppear(() => { this.inputAppeared(`inline_check_${item.id}`) })
          .onDisAppear(() => { this.inputDisappeared(`inline_check_${item.id}`) })
          .onVisibleAreaChange([0, 1], (visible: boolean) => { if (visible) this.inputVisible(`inline_check_${item.id}`) })
          .onSubmit((_key: EnterKeyType, event?: SubmitEvent) => { event?.keepEditableState(); this.editSubmit() })
      } else {
        Text(item.text).layoutWeight(1).fontSize(14).fontColor(item.checked ? UiColor.disabled : UiColor.text)
          .decoration({ type: item.checked ? TextDecorationType.LineThrough : TextDecorationType.None })
          .onClick(() => { if (this.editable) this.edit(item) })
      }
      if (this.editable) {
        Button({ type: ButtonType.Circle }) { Image($r('app.media.ui_delete')).width(20).height(20) }
          .width(36).height(44).padding(0).backgroundColor(Color.Transparent)
          .enabled(!this.disabled()).accessibilityText(`删除清单条目：${item.text}`)
          .onClick(() => { this.remove(item) })
      }
    }.width('100%').constraintSize({ minHeight: 44 }).padding({ left: Math.min(item.depth, 6) * 12 })
  }

  @Builder
  addRow() {
    Row({ space: 4 }) {
      Text('○').width(28).fontSize(19).fontColor(UiColor.secondary)
      TextInput({ text: this.newText, placeholder: '清单项' }).id(`inline_new_check_${this.ownerKey}`)
        .enabled(!this.disabled()).layoutWeight(1).fontSize(14).fontColor(UiColor.text)
        .backgroundColor(Color.Transparent).padding(0).enterKeyType(EnterKeyType.Next)
        .onFocus(() => { this.focused() }).onChange((text: string) => { this.newChanged(text) })
        .onBlur(() => { this.newBlur() })
        .onAppear(() => { this.inputAppeared(`inline_new_check_${this.ownerKey}`) })
        .onDisAppear(() => { this.inputDisappeared(`inline_new_check_${this.ownerKey}`) })
        .onVisibleAreaChange([0, 1], (visible: boolean) => { if (visible) this.inputVisible(`inline_new_check_${this.ownerKey}`) })
        .onSubmit((_key: EnterKeyType, event?: SubmitEvent) => { event?.keepEditableState(); this.newSubmit() })
    }.width('100%').height(44).padding({ left: 0 })
  }

  build() {
    Column() {
      ForEach(this.items, (item: CoreTaskChecklistItem) => {
        this.row(item)
      }, (item: CoreTaskChecklistItem) => `${item.id}:${item.text}:${item.checked}:${item.partial}`)
      if (this.editable && this.adding) { this.addRow() }
      if (this.editable && this.showAdd) {
        Text('+  添加清单项').fontSize(14).fontColor(UiColor.secondary).width('100%').height(44)
          .enabled(!this.disabled()).onClick(() => { this.add() })
      }
    }.width('100%')
  }
}
