import { ProjectNavigation } from '../services/ProjectNavigation'
import { TaskRegion, taskRegionTitle } from '../ui/TaskRegionPresentation'
import { UiColor } from '../ui/Theme'

@Component
export struct TaskRegionHeader {
  @Prop region: TaskRegion
  @Prop category: boolean = true
  @Prop project: boolean = true

  build() {
    if (taskRegionTitle(this.region, this.category, this.project)) {
      if (this.region.kind === 'project' && this.project) {
        Text(taskRegionTitle(this.region, this.category, this.project)).fontSize(12).fontColor(UiColor.projectLabel).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').padding({ left: 8, right: 8 })
          .accessibilityText(`打开项目：${taskRegionTitle(this.region, this.category, this.project)}`)
          .onClick((): void => {
            ProjectNavigation.open(this.getUIContext(), this.region.repoId, this.region.filePath)
          })
      } else {
        Text(taskRegionTitle(this.region, this.category, this.project)).fontSize(12).fontColor(UiColor.projectLabel).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').padding({ left: 8, right: 8 })
      }
    }
  }
}
