import { localizedText } from '../ui/LocalizedText'
import { UiColor } from '../ui/Theme'

@Component
export struct OrgFileEditBar {
  @Prop busy: boolean = false
  @Prop stale: boolean = false
  @Prop changed: boolean = false
  @Prop message: string = ''
  @Prop dragHint: string = ''
  save: () => void = () => {}
  discard: () => void = () => {}

  build() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(this.busy ? localizedText($r('app.string.text_saving_order')) : this.dragHint || localizedText($r('app.string.text_drag_to_the_middle_of_the_line')))
          .id('project_order_drop_hint').fontSize(13).lineHeight(18).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(this.dragHint ? UiColor.primary : UiColor.secondary).layoutWeight(1)
        Button($r('app.string.text_abandon')).id('project_order_discard').fontColor(UiColor.secondary).backgroundColor(Color.Transparent).height(44)
          .enabled(!this.busy).onClick(this.discard)
        Button($r('app.string.text_save')).id('project_order_save').fontColor(UiColor.surface).backgroundColor(UiColor.primary).height(44)
          .enabled(this.changed && !this.busy && !this.stale).onClick(this.save)
      }.width('100%')
      if (this.message || this.stale) {
        Text(this.stale ? localizedText($r('app.string.text_the_item_has_been_updated_and_please')) : this.message)
          .fontSize(13).fontColor(UiColor.error).width('100%')
      }
    }.width('100%').padding({ left: 14, right: 14, top: 8, bottom: 10 }).backgroundColor(UiColor.dialog)
  }
}
