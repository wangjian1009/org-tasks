import { TaskRegion } from '../ui/TaskRegionPresentation'
import { UiColor } from '../ui/Theme'
import { TaskRegionHeader } from './TaskRegionHeader'

// 普通区块与原生列表分组共用标题和容器样式，列表模式保留逐任务侧滑。
@Component
export struct TaskGroup {
  @Prop region: TaskRegion
  @Prop category: boolean = true
  @Prop project: boolean = true
  @Prop listMode: boolean = false
  @BuilderParam content: () => void

  @Builder
  header() {
    TaskRegionHeader({ region: this.region, category: this.category, project: this.project })
  }

  @Styles
  groupStyle() {
    .width('100%').padding({ left: 4, right: 4 })
      .backgroundColor(UiColor.projectBlock).borderRadius(12)
      .border({ width: 0.75, color: UiColor.projectOutline }).margin({ top: 4 })
  }

  build() {
    if (this.listMode) {
      ListItemGroup({ header: this.header() }) {
        this.content()
      }.groupStyle()
    } else {
      Column() {
        this.header()
        this.content()
      }.alignItems(HorizontalAlign.Start).groupStyle()
    }
  }
}
