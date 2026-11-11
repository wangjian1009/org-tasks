import { UiColor } from '../ui/Theme'

@Component
export struct InboxSwipeActions {
  @Prop busy: boolean = false
  move: () => void = () => {}
  someday: () => void = () => {}
  memo: () => void = () => {}
  remove: () => void = () => {}
  select: () => void = () => {}

  @Builder
  action(icon: Resource, text: string, label: string, key: string, activate: () => void) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 3 }) {
        Image(icon).width(20).height(20).accessibilityLevel('no')
          .fillColor(key === 'inbox_swipe_delete' ? UiColor.error : UiColor.text)
        Text(text).fontSize(11).fontColor(key === 'inbox_swipe_delete' ? UiColor.error : UiColor.text)
      }
    }.id(key).width(48).height(44).padding(0).backgroundColor(Color.Transparent).enabled(!this.busy)
      .accessibilityText(label).onClick(activate)
      .gesture(LongPressGesture().onAction((): void => {
        this.getUIContext().getPromptAction().showToast({ message: label })
      }))
  }

  build() {
    Row() {
      Row() {
        this.action($r('app.media.ui_move_to'), '移动', '移动', 'inbox_swipe_move', this.move)
        this.action($r('app.media.nav_someday'), '将来', '将来，也许', 'inbox_swipe_someday', this.someday)
        this.action($r('app.media.nav_memo'), '备忘', '转换为备忘', 'inbox_swipe_memo', this.memo)
        this.action($r('app.media.ui_delete'), '删除', '删除', 'inbox_swipe_delete', this.remove)
        Button({ type: ButtonType.Normal }) {
          Column({ space: 3 }) {
            Image($r('app.media.ui_select_records')).width(20).height(20).accessibilityLevel('no')
            Text('多选').fontSize(11).fontColor(Color.White)
          }
        }.id('inbox_swipe_select').width(48).height(44).padding(0).backgroundColor(UiColor.selection)
          .enabled(!this.busy).accessibilityText('多选并合并记录').onClick(this.select)
      }.backgroundColor('#35383E').borderRadius(12).clip(true)
    }.width(256).height('100%').padding({ left: 4, right: 12 }).alignItems(VerticalAlign.Center)
  }
}
