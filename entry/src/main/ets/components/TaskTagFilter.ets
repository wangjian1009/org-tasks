import { LengthMetrics } from '@kit.ArkUI'
import { TaskTagSelection, toggleTaskTag, groupedTaskTags } from '../ui/TaskTagFilterPresentation'
import { UiColor } from '../ui/Theme'

@Component
struct TaskTagChip {
  @Prop label: string = ''
  @Prop selected: boolean = false
  @Prop all: boolean = false
  @Prop chipWidth: number = 0
  activate: () => void = () => {}

  build() {
    Button({ type: ButtonType.Normal }) {
      Text(this.label).fontSize(14).fontWeight(FontWeight.Medium)
        .fontColor(this.selected ? '#25282C' : UiColor.secondary)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 88 })
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .backgroundColor(this.selected ? (this.all ? '#AEACA9' : '#6EA8FF') : Color.Transparent).borderRadius(16)
    }.width(this.chipWidth > 0 ? this.chipWidth : 'auto').height(32).padding(0).borderRadius(18)
      .backgroundColor(Color.Transparent).flexShrink(0)
      .accessibilityText(`${this.label}，${this.selected ? '已选中' : '未选中'}`)
      .onClick((): void => { this.activate() })
  }
}

// 今天、随时、某天和备忘共用的标签筛选条。
@Component
export struct TaskTagFilter {
  @Prop tags: string[] = []
  @Prop selectedTags: string[] = []
  @Prop includeUntagged: boolean = false
  @Prop exclusiveGroups: string[][] = []
  changed: (selection: TaskTagSelection) => void = () => {}
  @State expanded: boolean = false
  @State availableWidth: number = 0

  allSelected(): boolean { return this.selectedTags.length === 0 && !this.includeUntagged }

  selection(): TaskTagSelection { return { tags: this.selectedTags, includeUntagged: this.includeUntagged } }

  tagGroups(): string[][] { return groupedTaskTags(this.tags, this.exclusiveGroups) }

  tagChipWidth(label: string): number {
    const width = this.getUIContext().getMeasureUtils().measureText({
      textContent: label, fontSize: 14, fontWeight: FontWeight.Medium
    })
    // 保留测量精度，逐项取整会累积宽度误差，使本来能放下的标签提前换行。
    return Math.min(104, this.getUIContext().px2vp(width) + 16)
  }

  toggleWidth(): number { return 32 }

  usableWidth(): number {
    return Math.max(0, this.availableWidth - this.toggleWidth() - 2)
  }

  fixedChipWidth(): number {
    return this.tagChipWidth('全部') + this.tagChipWidth('无标签') + 2
  }

  remainingTagWidth(): number {
    // Flex 的第一个标签与“无标签”之间也会占一个间距。
    return Math.max(0, this.usableWidth() - this.fixedChipWidth() - 2)
  }

  overflows(): boolean {
    if (this.availableWidth <= 0) return false
    const tagsWidth = this.tagGroups().reduce((total: number, group: string[]): number => {
      return total + group.reduce((width: number, tag: string): number => width + this.tagChipWidth(tag) + 2, 0)
    }, 0)
    return this.fixedChipWidth() + tagsWidth > this.availableWidth
  }

  displayTags(): string[] {
    const tags = this.tagGroups().reduce((all: string[], group: string[]): string[] => all.concat(group), [])
    if (this.expanded || !this.overflows()) return tags
    let remaining = this.remainingTagWidth()
    const visible: string[] = []
    // 始终沿用候选顺序，不用后面的短标签补空位，也不把已选项前移。
    for (const tag of tags) {
      const width = this.tagChipWidth(tag)
      const gap = visible.length > 0 ? 2 : 0
      if (width + gap > remaining) break
      visible.push(tag)
      remaining -= width + gap
    }
    return visible
  }

  dividerBefore(index: number): boolean {
    if (!this.expanded || this.exclusiveGroups.length === 0) return false
    let offset = 0
    for (const group of this.tagGroups()) {
      if (offset > 0 && index === offset) return true
      offset += group.length
    }
    return false
  }

  @Builder
  expandButton() {
    Button({ type: ButtonType.Normal }) {
      Image(this.expanded ? $r('app.media.ui_up') : $r('app.media.ui_down'))
        .width(14).height(14).fillColor(UiColor.secondary).accessibilityLevel('no')
    }.width(this.toggleWidth()).height(32).padding(0)
      .backgroundColor(Color.Transparent).borderRadius(16).flexShrink(0)
      .accessibilityText(this.expanded ? '收起全部标签筛选' : '展开全部标签筛选')
      .onClick((): void => { this.expanded = !this.expanded })
  }

  build() {
    Row({ space: 2 }) {
      Flex({ wrap: this.expanded ? FlexWrap.Wrap : FlexWrap.NoWrap, alignItems: ItemAlign.Center,
        space: { main: LengthMetrics.vp(2), cross: LengthMetrics.vp(0) } }) {
        TaskTagChip({ label: '全部', selected: this.allSelected(), all: true, chipWidth: this.tagChipWidth('全部'), activate: (): void => {
          this.changed({ tags: [], includeUntagged: false })
        } })
        TaskTagChip({ label: '无标签', selected: this.includeUntagged, chipWidth: this.tagChipWidth('无标签'), activate: (): void => {
          this.changed({ tags: this.selectedTags, includeUntagged: !this.includeUntagged })
        } })
        ForEach(this.displayTags(), (tag: string, index: number) => {
          if (this.dividerBefore(index)) {
            Divider().vertical(true).height(16).color(UiColor.outline).margin({ left: 3, right: 3 })
          }
          TaskTagChip({ label: tag, selected: this.selectedTags.includes(tag), chipWidth: this.tagChipWidth(tag), activate: (): void => {
            this.changed(toggleTaskTag(this.selection(), tag, this.exclusiveGroups))
          } })
        }, (tag: string) => tag)
      }.layoutWeight(1)
      if (this.overflows() || this.expanded) { this.expandButton() }
    }.width('100%').alignItems(VerticalAlign.Top).padding({ left: 12, right: 12, top: 2, bottom: 2 })
      .backgroundColor(UiColor.surface).flexShrink(0)
      .onAreaChange((_old: Area, area: Area): void => {
        const width = Math.max(0, Number(area.width) - 24)
        if (width !== this.availableWidth) this.availableWidth = width
      })
  }
}
