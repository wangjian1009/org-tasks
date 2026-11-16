import { LengthMetrics } from '@kit.ArkUI'
import { ProjectHeaderTagSegment, projectHeaderRows } from '../ui/ProjectHeaderPresentation'
import { UiColor } from '../ui/Theme'

// 文件配置与文档正文分区；候选按文件头声明分行，同组使用共享边框。
@Component
export struct ProjectFileHeader {
  @Prop fileTags: string[] = []
  @Prop tags: string[] = []
  @Prop rows: string[][] = []
  @Prop groups: string[][] = []
  @Prop selectedTags: string[] = []
  toggle: (tag: string) => void = () => {}
  clear: () => void = () => {}

  chipWidth(tag: string): number {
    const width = this.getUIContext().getMeasureUtils().measureText({
      textContent: this.selectedTags.includes(tag) ? `✓ ${tag}` : tag, fontSize: 13
    })
    return Math.min(220, this.getUIContext().px2vp(width) + 20)
  }

  groupWidth(tags: string[]): number {
    return tags.reduce((width: number, tag: string) => width + this.chipWidth(tag), 0) + (tags.length - 1) * 4 + 10
  }

  @Builder
  tagChip(tag: string) {
    Button({ type: ButtonType.Normal }) {
      Text(this.selectedTags.includes(tag) ? `✓ ${tag}` : tag).fontSize(13)
        .fontColor(this.selectedTags.includes(tag) ? UiColor.surface : UiColor.text)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width(this.chipWidth(tag)).constraintSize({ minHeight: 32, maxWidth: 220 }).padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(8).backgroundColor(this.selectedTags.includes(tag) ? UiColor.primary : UiColor.surface)
      .accessibilityText(`${tag}，${this.selectedTags.includes(tag) ? '已选中，点击取消筛选' : '未选中，点击加入筛选'}`)
      .onClick((): void => { this.toggle(tag) })
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 10 }) {
          Row() {
            Text('文件配置').fontSize(12).fontWeight(FontWeight.Medium).fontColor(UiColor.secondary).layoutWeight(1)
            if (this.selectedTags.length > 0) {
              Button('清除筛选', { type: ButtonType.Normal }).fontSize(12).fontColor(UiColor.primary)
                .backgroundColor(Color.Transparent).padding({ left: 8, right: 0 }).height(32)
                .onClick((): void => { this.clear() })
            }
          }.width('100%').constraintSize({ minHeight: 32 })
          if (this.fileTags.length > 0) {
            Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
              space: { main: LengthMetrics.vp(6), cross: LengthMetrics.vp(6) } }) {
              Text('文件标签').fontSize(12).fontColor(UiColor.secondary)
              ForEach(this.fileTags, (tag: string) => {
                Text(tag).fontSize(12).fontColor(UiColor.secondary).padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .borderRadius(6).border({ width: 1, color: UiColor.outline })
              }, (tag: string) => tag)
            }.width('100%')
          }
          ForEach(projectHeaderRows(this.rows, this.tags, this.groups), (row: ProjectHeaderTagSegment[]) => {
            Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
              space: { main: LengthMetrics.vp(6), cross: LengthMetrics.vp(6) } }) {
              ForEach(row, (segment: ProjectHeaderTagSegment) => {
                if (segment.grouped) {
                  Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
                    space: { main: LengthMetrics.vp(4), cross: LengthMetrics.vp(4) } }) {
                    ForEach(segment.tags, (tag: string) => { this.tagChip(tag) }, (tag: string) => tag)
                  }.width(this.groupWidth(segment.tags)).constraintSize({ maxWidth: '100%' }).padding(4)
                    .borderRadius(12).border({ width: 1, color: UiColor.outline })
                    .accessibilityDescription('互斥标签组，同组最多选择一个标签')
                } else {
                  this.tagChip(segment.tags[0])
                }
              })
            }.width('100%')
          })
        }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
      }.width('100%').constraintSize({ maxHeight: 240 }).scrollBar(BarState.Auto)
        .backgroundColor(UiColor.projectBlock).borderRadius(12)
    }.width('100%').padding({ left: 12, right: 12, top: 8, bottom: 12 }).flexShrink(0)
  }
}
