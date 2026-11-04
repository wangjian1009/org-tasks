import { router } from '@kit.ArkUI'
import { TodaySection, TodayTaskItem } from '../ui/TodayPresentation'
import { UiColor } from '../ui/Theme'
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
                Text(item.task.heading).fontSize(16).fontColor(UiColor.text)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
                if (item.overdueDays > 0) {
                  Text(`${item.overdueDays}`).fontSize(13).fontColor(UiColor.error)
                    .accessibilityText(`已过期 ${item.overdueDays} 天`)
                }
              }.width('100%').constraintSize({ minHeight: 44 }).padding({ top: 10, bottom: 10 })
                .accessibilityGroup(true)
                .accessibilityText(`${item.task.heading}${item.overdueDays > 0 ? `，已过期 ${item.overdueDays} 天` : ''}`)
                .onClick((): void => { router.pushUrl({ url: 'pages/TaskDetail', params: { task: item.task } }) })
            }
          }, (item: TodayTaskItem) => item.task.id)
        }
      }, (section: TodaySection) => section.key)
    }.width('100%').layoutWeight(1).padding({ left: 20, right: 20, bottom: 88 })
      .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .edgeEffect(EdgeEffect.None)
  }
}
