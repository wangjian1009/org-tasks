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
        Text(this.busy ? '正在保存顺序' : this.dragHint || '拖到行中间成为子项\n拖到上下缘调整顺序')
          .id('project_order_drop_hint').fontSize(13).lineHeight(18).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(this.dragHint ? UiColor.primary : UiColor.secondary).layoutWeight(1)
        Button('放弃').id('project_order_discard').fontColor(UiColor.secondary).backgroundColor(Color.Transparent).height(44)
          .enabled(!this.busy).onClick(this.discard)
        Button('保存').id('project_order_save').fontColor(UiColor.surface).backgroundColor(UiColor.primary).height(44)
          .enabled(this.changed && !this.busy && !this.stale).onClick(this.save)
      }.width('100%')
      if (this.message || this.stale) {
        Text(this.stale ? '项目已更新，请放弃本次调整后重新进入排序。' : this.message)
          .fontSize(13).fontColor(UiColor.error).width('100%')
      }
    }.width('100%').padding({ left: 14, right: 14, top: 8, bottom: 10 }).backgroundColor(UiColor.dialog)
  }
}
