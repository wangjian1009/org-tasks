import { ProjectNavigation } from '../services/ProjectNavigation'
import { TaskRegion } from '../ui/TaskRegionPresentation'
import { UiColor } from '../ui/Theme'

@Component
export struct TaskRegionHeader {
  @Prop region: TaskRegion

  build() {
    if (this.region.kind === 'project') {
      Button({ type: ButtonType.Normal }) {
        Text(this.region.title).fontSize(12).fontColor(UiColor.projectLabel).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }.width('100%').constraintSize({ minHeight: 48 }).padding({ left: 8, right: 8, top: 8, bottom: 2 })
        .backgroundColor(Color.Transparent).accessibilityText(`打开项目：${this.region.title}`)
        .onClick((): void => {
          ProjectNavigation.open(this.getUIContext(), this.region.repoId, this.region.filePath)
        })
    } else {
      Text(this.region.title).fontSize(12).fontColor(UiColor.projectLabel).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        .padding({ left: 8, right: 8, top: 8, bottom: 2 }).constraintSize({ minHeight: 48 })
    }
  }
}
