import { LengthMetrics } from '@kit.ArkUI'
import { TaskRegionData } from '../ui/TaskRegionPresentation'
import { UiColor } from '../ui/Theme'

@Component
export struct RegionProjectFilter {
  @Prop options: TaskRegionData[] = []
  @Prop selectedKey: string = ''
  changed: (region: TaskRegionData | null) => void = () => {}
  @State expanded: boolean = false
  @State availableWidth: number = 0

  chipWidth(label: string): number {
    const width = this.getUIContext().getMeasureUtils().measureText({
      textContent: label, fontSize: 14, fontWeight: FontWeight.Medium
    })
    return Math.min(this.availableWidth, Math.ceil(Math.min(128, this.getUIContext().px2vp(width))) + 22)
  }

  toggleWidth(): number { return 32 }

  overflows(): boolean {
    if (this.availableWidth <= 0) return false
    let width = this.chipWidth('全部')
    for (const region of this.options) width += 6 + this.chipWidth(region.title)
    return width > this.availableWidth
  }

  collapsedOptions(): TaskRegionData[] {
    if (!this.overflows()) return this.options
    const selected = this.options.find((region: TaskRegionData) => region.key === this.selectedKey)
    // 收起时优先保留当前选择，避免筛选条件藏在展开区域。
    const candidates = selected ? [selected].concat(this.options.filter((region: TaskRegionData) => region.key !== selected.key)) : this.options
    let remaining = this.availableWidth - this.chipWidth('全部') - this.toggleWidth() - 12
    const visible: TaskRegionData[] = []
    for (const region of candidates) {
      const width = this.collapsedChipWidth(region)
      if (width > remaining) break
      visible.push(region)
      remaining -= width + 6
    }
    return visible
  }

  collapsedChipWidth(region: TaskRegionData): number {
    const remaining = this.availableWidth - this.chipWidth('全部') - this.toggleWidth() - 12
    return Math.min(this.chipWidth(region.title), Math.max(0, remaining))
  }

  chipBackground(region: TaskRegionData | null, selected: boolean): string {
    if (region === null) return selected ? '#AEACA9' : UiColor.field
    if (region.kind === 'project') return selected ? '#A4BDEB' : '#34465F'
    return selected ? '#91C7B5' : '#304B46'
  }

  @Builder
  chip(label: string, selected: boolean, region: TaskRegionData | null) {
    Button({ type: ButtonType.Normal }) {
      Row() {
        Text(label).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(selected ? '#25282C' : region === null ? UiColor.secondary : UiColor.text)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 128 }).flexShrink(1)
      }.width('100%').padding({ left: 11, right: 11, top: 4, bottom: 4 })
        .backgroundColor(this.chipBackground(region, selected))
        .borderRadius(16)
    }.width(region !== null && !this.expanded && this.overflows() ? this.collapsedChipWidth(region) : this.chipWidth(label))
      .height(44).padding(0).borderRadius(18).backgroundColor(Color.Transparent).flexShrink(0)
      .accessibilityText(`${region === null ? '' : region.kind === 'project' ? '项目：' : '分类：'}${label}，${selected ? '已选中' : '未选中'}`)
      .onClick((): void => { this.changed(selected ? null : region) })
  }

  @Builder
  expandButton() {
    Button({ type: ButtonType.Normal }) {
      Image(this.expanded ? $r('app.media.ui_up') : $r('app.media.ui_down'))
        .width(14).height(14).fillColor(UiColor.secondary).accessibilityLevel('no')
    }.width(this.toggleWidth()).height(44).padding(0)
      .backgroundColor(Color.Transparent).borderRadius(16).flexShrink(0)
      .accessibilityText(this.expanded ? '收起分类与项目筛选' : '展开全部分类与项目筛选')
      .onClick((): void => { this.expanded = !this.expanded })
  }

  build() {
    Row({ space: 6 }) {
      Flex({ wrap: this.expanded ? FlexWrap.Wrap : FlexWrap.NoWrap, alignItems: ItemAlign.Center,
        space: { main: LengthMetrics.vp(6) } }) {
        this.chip('全部', this.selectedKey.length === 0, null)
        ForEach(this.expanded ? this.options : this.collapsedOptions(), (region: TaskRegionData) => {
          this.chip(region.title, this.selectedKey === region.key, region)
        }, (region: TaskRegionData) => region.key)
      }.layoutWeight(1)
      if (this.overflows() || this.expanded) { this.expandButton() }
    }.width('100%').alignItems(VerticalAlign.Top).padding({ left: 12, right: 12, top: 4, bottom: 4 })
      .backgroundColor(UiColor.surface).flexShrink(0)
      .onAreaChange((_old: Area, area: Area): void => {
        const width = Math.max(0, Number(area.width) - 24)
        if (width !== this.availableWidth) this.availableWidth = width
      })
  }
}
