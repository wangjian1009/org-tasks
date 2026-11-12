import { TaskTagSelection, toggleTaskTag, groupedTaskTags } from '../ui/TaskTagFilterPresentation'
import { UiColor } from '../ui/Theme'
import { PopupMenuButton } from './PopupMenuButton'

@Component
struct TaskTagChip {
  @Prop label: string = ''
  @Prop selected: boolean = false
  @Prop all: boolean = false
  activate: () => void = () => {}

  build() {
    Button({ type: ButtonType.Normal }) {
      Text(this.label).fontSize(14).fontWeight(FontWeight.Medium)
        .fontColor(this.selected ? '#25282C' : UiColor.secondary)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 88 })
        .padding({ left: 11, right: 11, top: 4, bottom: 4 })
        .backgroundColor(this.selected ? (this.all ? '#AEACA9' : '#6EA8FF') : Color.Transparent).borderRadius(16)
    }.height(44).borderRadius(18).backgroundColor(Color.Transparent).flexShrink(0)
      .accessibilityText(`${this.label}，${this.selected ? '已选中' : '未选中'}`)
      .onClick((): void => { this.activate() })
  }
}

@Component
export struct TaskTagFilter {
  @Prop tags: string[] = []
  @Prop selectedTags: string[] = []
  @Prop includeUntagged: boolean = false
  @Prop exclusiveGroups: string[][] = []
  changed: (selection: TaskTagSelection) => void = () => {}

  allSelected(): boolean { return this.selectedTags.length === 0 && !this.includeUntagged }

  selection(): TaskTagSelection { return { tags: this.selectedTags, includeUntagged: this.includeUntagged } }

  build() {
    Row({ space: 2 }) {
      TaskTagChip({ label: '全部', selected: this.allSelected(), all: true, activate: (): void => {
        this.changed({ tags: [], includeUntagged: false })
      } })
      Scroll() {
        Row({ space: 2 }) {
          if (this.includeUntagged) {
            TaskTagChip({ label: '无标签', selected: true, activate: (): void => {
              this.changed({ tags: this.selectedTags, includeUntagged: false })
            } })
          }
          if (this.exclusiveGroups.length > 0) {
            ForEach(groupedTaskTags(this.tags, this.exclusiveGroups), (group: string[], index: number) => {
              Row({ space: 2 }) {
                if (index > 0) { Divider().vertical(true).height(18).color(UiColor.outline).margin({ left: 6, right: 6 }) }
                ForEach(group, (tag: string) => {
                  TaskTagChip({ label: tag, selected: this.selectedTags.includes(tag), activate: (): void => {
                    this.changed(toggleTaskTag(this.selection(), tag, this.exclusiveGroups))
                  } })
                }, (tag: string) => tag)
              }.alignItems(VerticalAlign.Center)
            }, (group: string[]) => JSON.stringify(group))
          } else {
            ForEach(this.tags, (tag: string) => {
              TaskTagChip({ label: tag, selected: this.selectedTags.includes(tag), activate: (): void => {
                this.changed(toggleTaskTag(this.selection(), tag))
              } })
            }, (tag: string) => tag)
          }
        }.alignItems(VerticalAlign.Center)
      }.layoutWeight(1).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None).align(Alignment.Start)
      PopupMenuButton({ icon: $r('app.media.ui_more_horizontal'), label: '更多标签筛选，无标签',
        buttonWidth: 40, buttonHeight: 44, iconSize: 20,
        items: [{ title: '无标签', checked: this.includeUntagged, action: (): void => {
          this.changed({ tags: this.selectedTags, includeUntagged: !this.includeUntagged })
        } }] })
    }.width('100%').padding({ left: 12, right: 12, top: 4, bottom: 4 })
      .alignItems(VerticalAlign.Center).backgroundColor(UiColor.surface)
  }
}
