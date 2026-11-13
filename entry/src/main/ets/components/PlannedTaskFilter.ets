import { TaskRegionData } from '../ui/TaskRegionPresentation'
import { UiColor } from '../ui/Theme'

@Component
export struct PlannedTaskFilter {
  @Prop options: TaskRegionData[] = []
  @Prop selectedKey: string = ''
  changed: (region: TaskRegionData | null) => void = () => {}

  @Builder
  chip(label: string, selected: boolean, region: TaskRegionData | null) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 4 }) {
        if (region !== null) {
          Image(region.kind === 'project' ? $r('app.media.ui_folder') : $r('app.media.ui_category'))
            .width(14).height(14).fillColor(selected ? '#25282C' : UiColor.secondary)
        }
        Text(label).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(selected ? '#25282C' : UiColor.secondary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 128 })
      }.padding({ left: 11, right: 11, top: 4, bottom: 4 })
        .backgroundColor(selected ? (region === null ? '#AEACA9' : '#6EA8FF') : Color.Transparent)
        .borderRadius(16)
    }.height(44).borderRadius(18).backgroundColor(Color.Transparent).flexShrink(0)
      .accessibilityText(`${region === null ? '' : region.kind === 'project' ? '项目：' : '分类：'}${label}，${selected ? '已选中' : '未选中'}`)
      .onClick((): void => { this.changed(selected ? null : region) })
  }

  build() {
    Row({ space: 2 }) {
      this.chip('全部', this.selectedKey.length === 0, null)
      Scroll() {
        Row({ space: 2 }) {
          ForEach(this.options, (region: TaskRegionData, index: number) => {
            if (index > 0 && region.kind !== this.options[index - 1].kind) {
              Divider().vertical(true).height(18).color(UiColor.outline).margin({ left: 6, right: 6 })
            }
            this.chip(region.title, this.selectedKey === region.key, region)
          }, (region: TaskRegionData) => region.key)
        }.alignItems(VerticalAlign.Center)
      }.layoutWeight(1).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None).align(Alignment.Start)
    }.width('100%').padding({ left: 12, right: 12, top: 4, bottom: 4 })
      .alignItems(VerticalAlign.Center).backgroundColor(UiColor.surface)
  }
}
