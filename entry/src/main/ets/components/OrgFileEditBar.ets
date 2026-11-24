import { UiColor } from '../ui/Theme'

@Component
export struct OrgFileEditBar {
  @Prop busy: boolean = false
  @Prop stale: boolean = false
  @Prop message: string = ''
  cancel: () => void = () => {}

  build() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(this.busy ? '正在保存顺序' : '长按手柄拖动排序')
          .fontSize(13).fontColor(this.busy ? UiColor.secondary : UiColor.text).layoutWeight(1)
        Button('退出').fontColor(UiColor.secondary).backgroundColor(Color.Transparent).height(44)
          .enabled(!this.busy).onClick(this.cancel)
      }.width('100%')
      if (this.message || this.stale) {
        Text(this.stale ? '项目已更新，请退出后重新进入排序。' : this.message)
          .fontSize(13).fontColor(UiColor.error).width('100%')
      }
    }.width('100%').padding({ left: 14, right: 14, top: 8, bottom: 10 }).backgroundColor(UiColor.dialog)
  }
}
