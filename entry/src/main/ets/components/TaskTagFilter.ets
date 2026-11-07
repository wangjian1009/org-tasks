import { TaskTagSelection, toggleTaskTag } from '../ui/TaskTagFilterPresentation'
import { UiColor } from '../ui/Theme'

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
  changed: (selection: TaskTagSelection) => void = () => {}

  allSelected(): boolean { return this.selectedTags.length === 0 && !this.includeUntagged }

  selection(): TaskTagSelection { return { tags: this.selectedTags, includeUntagged: this.includeUntagged } }

  @Builder
  moreMenu() {
    Menu() {
      MenuItem({ content: '无标签', labelInfo: this.includeUntagged ? '✓' : '' })
        .contentFontColor(UiColor.text).labelFontColor(UiColor.text)
        .onClick((): void => {
          this.changed({ tags: this.selectedTags, includeUntagged: !this.includeUntagged })
        })
    }.backgroundColor(UiColor.taskCard)
  }

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
          ForEach(this.tags, (tag: string) => {
            TaskTagChip({ label: tag, selected: this.selectedTags.includes(tag), activate: (): void => {
              this.changed(toggleTaskTag(this.selection(), tag))
            } })
          }, (tag: string) => tag)
        }.alignItems(VerticalAlign.Center)
      }.layoutWeight(1).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None).align(Alignment.Start)
      Button({ type: ButtonType.Normal }) {
        Text('…').fontSize(22).fontColor(this.includeUntagged ? '#6EA8FF' : UiColor.secondary)
      }.width(40).height(44).backgroundColor(Color.Transparent).borderRadius(18)
        .accessibilityText('更多标签筛选，无标签').bindMenu(this.moreMenu)
    }.width('100%').padding({ left: 12, right: 12, top: 4, bottom: 4 })
      .alignItems(VerticalAlign.Center).backgroundColor(UiColor.surface)
  }
}
