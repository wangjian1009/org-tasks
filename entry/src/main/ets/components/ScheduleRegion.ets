import { UiColor } from '../ui/Theme'

// 计划按日区域的日程标题，沿用分类标题的图标、文字与分割线布局。
@Component
export struct ScheduleRegion {
  build() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Image($r('app.media.ui_task_calendar')).width(22).height(22)
          .accessibilityText('日程')
        Text('日程').fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%')
      Divider().color(UiColor.outline).strokeWidth(0.5)
    }.width('100%').padding({ left: 8, right: 8, top: 24, bottom: 8 }).backgroundColor(UiColor.surface)
  }
}
