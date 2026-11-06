import { taskRenderKey } from '../ui/TaskPresentation'
import { CoreTitlePart } from '../services/NativeCoreService'
import { router } from '@kit.ArkUI'
import { TodaySection, TodayTaskItem } from '../ui/TodayPresentation'
import { UiColor } from '../ui/Theme'
import { TitleText } from './TitleText'
import { ListSectionHeader } from './Controls'

@Component
export struct TodayTaskList {
  @Prop sections: TodaySection[] = []

  @Builder
  sectionHeader(section: TodaySection) {
    ListSectionHeader({ title: section.category ?? '未分类' })
  }

  build() {
    List() {
      ForEach(this.sections, (section: TodaySection) => {
        ListItemGroup({ header: this.sectionHeader(section) }) {
          ForEach(section.items, (item: TodayTaskItem) => {
            ListItem() {
              Row({ space: 8 }) {
                TitleText({ text: item.task.heading, parts: item.task.headingParts, lineLimit: 1 }).flexShrink(1)
                if (item.overdueDays > 0) {
                  Text(`${item.overdueDays}`).fontSize(13).fontColor(UiColor.error)
                    .accessibilityText(`已过期 ${item.overdueDays} 天`)
                }
              }.width('100%').constraintSize({ minHeight: 44 }).padding({ top: 10, bottom: 10 })
                .accessibilityGroup(true)
                .accessibilityText(`${item.task.headingParts.map((part: CoreTitlePart) => part.text).join('')}${item.overdueDays > 0 ? `，已过期 ${item.overdueDays} 天` : ''}`)
                .onClick((): void => { router.pushUrl({ url: 'pages/TaskEdit', params: { task: item.task } }) })
            }
          }, (item: TodayTaskItem) => taskRenderKey(item.task))
        }
      }, (section: TodaySection) => JSON.stringify(section))
    }.width('100%').layoutWeight(1).padding({ left: 20, right: 20, bottom: 16 })
      .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .edgeEffect(EdgeEffect.None)
  }
}
