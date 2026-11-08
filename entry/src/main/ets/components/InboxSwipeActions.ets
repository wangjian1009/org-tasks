@Component
export struct InboxSwipeActions {
  @Prop busy: boolean = false
  move: () => void = () => {}
  someday: () => void = () => {}
  memo: () => void = () => {}
  remove: () => void = () => {}

  @Builder
  action(icon: Resource, label: string, color: string, key: string, activate: () => void) {
    Button({ type: ButtonType.Circle }) {
      Image(icon).width(24).height(24).accessibilityLevel('no')
    }.id(key).width(44).height(44).padding(0).backgroundColor(color).enabled(!this.busy)
      .accessibilityText(label).onClick(activate)
      .gesture(LongPressGesture().onAction((): void => {
        this.getUIContext().getPromptAction().showToast({ message: label })
      }))
  }

  build() {
    Row({ space: 8 }) {
      this.action($r('app.media.ui_move_to'), '移动', '#344A47', 'inbox_swipe_move', this.move)
      this.action($r('app.media.nav_someday'), '将来，也许', '#494637', 'inbox_swipe_someday', this.someday)
      this.action($r('app.media.nav_memo'), '转换为备忘', '#453C55', 'inbox_swipe_memo', this.memo)
      this.action($r('app.media.ui_delete_record'), '删除', '#513A40', 'inbox_swipe_delete', this.remove)
    }.width(220).height('100%').padding({ left: 8, right: 12 }).alignItems(VerticalAlign.Center)
  }
}
