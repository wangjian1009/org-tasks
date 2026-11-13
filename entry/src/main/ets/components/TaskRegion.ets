import { ProjectNavigation } from '../services/ProjectNavigation'
import { TaskRegionData, taskRegionTitle } from '../ui/TaskRegionPresentation'
import { UiColor } from '../ui/Theme'

// 所有任务区域共用原生列表分组，标题与容器样式只在此处维护。
@Component
export struct TaskRegion {
  @Prop category: string | null = null
  @Prop project: TaskRegionData | null = null
  @BuilderParam content: () => void = this.emptyContent

  @Builder
  emptyContent() {}

  @Builder
  titleContent() {
    Column() {
      Text(taskRegionTitle(this.category, this.project)).fontSize(12).fontWeight(FontWeight.Regular)
        .fontColor(UiColor.projectLabel)
        .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%').padding({ left: 8, right: 8, top: 10, bottom: 8 })
  }

  @Builder
  header() {
    if (taskRegionTitle(this.category, this.project)) {
      if (this.project !== null) {
        Column() { this.titleContent() }.width('100%')
          .accessibilityText(`打开项目：${taskRegionTitle(this.category, this.project)}`)
          .onClick((): void => {
            if (this.project !== null) {
              ProjectNavigation.open(this.getUIContext(), this.project.repoId, this.project.filePath)
            }
          })
      } else {
        this.titleContent()
      }
    }
  }

  build() {
    ListItemGroup({ header: this.header() }) {
      this.content()
    }.width('100%').backgroundColor(UiColor.projectBlock).borderRadius(12)
      .border({ width: 0.75, color: UiColor.projectOutline })
      .padding({ left: 4, right: 4, bottom: 8 }).margin({ top: 12 })
  }
}
