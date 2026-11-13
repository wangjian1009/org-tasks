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

  chipWidth(label: string, hasIcon: boolean): number {
    const width = this.getUIContext().getMeasureUtils().measureText({
      textContent: label, fontSize: 14, fontWeight: FontWeight.Medium
    })
    return Math.min(this.availableWidth, Math.ceil(Math.min(128, this.getUIContext().px2vp(width))) +
      (hasIcon ? 40 : 22))
  }

  toggleWidth(): number { return this.chipWidth('展开', false) }

  overflows(): boolean {
    if (this.availableWidth <= 0) return false
    let width = this.chipWidth('全部', false)
    for (const region of this.options) width += 6 + this.chipWidth(region.title, true)
    return width > this.availableWidth
  }

  collapsedOptions(): TaskRegionData[] {
    if (!this.overflows()) return this.options
    const selected = this.options.find((region: TaskRegionData) => region.key === this.selectedKey)
    // 收起时优先保留当前选择，避免筛选条件藏在展开区域。
    const candidates = selected ? [selected].concat(this.options.filter((region: TaskRegionData) => region.key !== selected.key)) : this.options
    let remaining = this.availableWidth - this.chipWidth('全部', false) - this.toggleWidth() - 12
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
    const remaining = this.availableWidth - this.chipWidth('全部', false) - this.toggleWidth() - 12
    return Math.min(this.chipWidth(region.title, true), Math.max(0, remaining))
  }

  @Builder
  chip(label: string, selected: boolean, region: TaskRegionData | null) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 4 }) {
        if (region !== null) {
          Image(region.kind === 'project' ? $r('app.media.ui_folder') : $r('app.media.ui_category'))
            .width(14).height(14).flexShrink(0).fillColor(selected ? '#25282C' : UiColor.secondary)
        }
        Text(label).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(selected ? '#25282C' : UiColor.secondary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 128 }).flexShrink(1)
      }.width('100%').padding({ left: 11, right: 11, top: 4, bottom: 4 })
        .backgroundColor(selected ? (region === null ? '#AEACA9' : '#6EA8FF') : UiColor.field)
        .borderRadius(16)
    }.width(region !== null && !this.expanded && this.overflows() ? this.collapsedChipWidth(region) : this.chipWidth(label, region !== null))
      .height(44).padding(0).borderRadius(18).backgroundColor(Color.Transparent).flexShrink(0)
      .accessibilityText(`${region === null ? '' : region.kind === 'project' ? '项目：' : '分类：'}${label}，${selected ? '已选中' : '未选中'}`)
      .onClick((): void => { this.changed(selected ? null : region) })
  }

  @Builder
  expandButton() {
    Button(this.expanded ? '收起' : '展开', { type: ButtonType.Normal })
      .width(this.toggleWidth()).height(44).padding(0).fontSize(14).fontColor(UiColor.secondary)
      .backgroundColor(Color.Transparent).borderRadius(16).flexShrink(0)
      .accessibilityText(this.expanded ? '收起分类与项目筛选' : '展开全部分类与项目筛选')
      .onClick((): void => { this.expanded = !this.expanded })
  }

  build() {
    Flex({ wrap: this.expanded ? FlexWrap.Wrap : FlexWrap.NoWrap, alignItems: ItemAlign.Center,
      space: { main: LengthMetrics.vp(6) } }) {
      this.chip('全部', this.selectedKey.length === 0, null)
      ForEach(this.expanded ? this.options : this.collapsedOptions(), (region: TaskRegionData) => {
        this.chip(region.title, this.selectedKey === region.key, region)
      }, (region: TaskRegionData) => region.key)
      if (this.overflows() || this.expanded) { this.expandButton() }
    }.width('100%').padding({ left: 12, right: 12, top: 4, bottom: 4 })
      .backgroundColor(UiColor.surface).flexShrink(0)
      .onAreaChange((_old: Area, area: Area): void => {
        const width = Math.max(0, Number(area.width) - 24)
        if (width !== this.availableWidth) this.availableWidth = width
      })
  }
}
