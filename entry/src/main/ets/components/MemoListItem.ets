import { CoreTask } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'
import { memoSummaryText } from '../ui/MemoListPresentation'
import { TitleText } from './TitleText'
import { OrgContentView } from './OrgContentView'

// 备忘列表的卡片只负责展示与折叠；内容仍由 Core 投影和 OrgContentView 提供。
@Component
export struct MemoListItem {
  @Prop task: CoreTask
  @State expanded: boolean = false
  @State contentMounted: boolean = false
  @State contentHeight: number = 0
  private measuredContentHeight: number = 0
  open: () => void = () => {}

  bodyText(): string { return this.task.body.trim() }

  toggle(): void {
    this.contentMounted = true
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => {
      this.expanded = !this.expanded
      this.contentHeight = this.expanded ? this.measuredContentHeight : 0
    })
  }

  measureContent(area: Area): void {
    const height = Math.ceil(parseFloat(area.height.toString()))
    if (!Number.isFinite(height) || height <= 0 || height === this.measuredContentHeight) return
    this.measuredContentHeight = height
    if (this.expanded) {
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => { this.contentHeight = height })
    }
  }

  @Builder
  titleRow() {
    Row({ space: 10 }) {
      Blank().width(4).height(28).backgroundColor('#F2C400').borderRadius(2).flexShrink(0)
      TitleText({ text: this.task.heading, parts: this.task.headingParts, textSize: 18,
        weight: FontWeight.Medium, lineLimit: this.expanded ? 0 : 1, showCounts: true })
        .layoutWeight(1).constraintSize({ minWidth: 0 })
      Image(this.expanded ? $r('app.media.ui_up') : $r('app.media.ui_down')).width(18).height(18)
        .opacity(0.8).flexShrink(0).accessibilityText(this.expanded ? '收起备忘' : '展开备忘')
    }.width('100%').alignItems(this.expanded ? VerticalAlign.Top : VerticalAlign.Center)
      .onClick((): void => { this.toggle() })
  }

  @Builder
  collapsedBody() {
    if (memoSummaryText(this.task).length > 0) {
      Text(memoSummaryText(this.task)).fontSize(15).fontColor(UiColor.secondary).lineHeight(22)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        .margin({ left: 14, top: 8 }).onClick((): void => { this.toggle() })
    }
  }

  @Builder
  detailsButton() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 6 }) {
        Text('详情').fontSize(13).fontColor(UiColor.secondary)
        Image($r('app.media.ui_next')).width(16).height(16)
      }
    }.height(36).padding({ left: 10, right: 10 }).borderRadius(10).backgroundColor(UiColor.field)
      .accessibilityText('打开备忘编辑').onClick((): void => { this.open() })
  }

  @Builder
  expandedContent() {
    Column({ space: 12 }) {
      if (this.task.bodyHtml.trim().length > 0) {
        OrgContentView({ fragment: this.task.bodyHtml, embedded: true,
          contentBackground: UiColor.taskCard, embeddedPadding: 0 }).width('100%')
      } else if (this.bodyText().length === 0) {
        Text('没有正文内容').fontSize(14).fontColor(UiColor.secondary).width('100%')
      }
      Row() { Blank().layoutWeight(1); this.detailsButton() }.width('100%')
    }.width('100%').padding({ left: 14, top: 12 }).alignItems(HorizontalAlign.Start)
      .onAreaChange((oldArea: Area, newArea: Area) => { this.measureContent(newArea) })
  }

  build() {
    Column({ space: 0 }) {
      this.titleRow()
      if (!this.expanded) this.collapsedBody()
      if (this.contentMounted) {
        // 内容高度由正文控件测量，纵向手势交给外层备忘列表。
        Scroll() { this.expandedContent() }.width('100%').height(this.contentHeight).clip(true)
          .scrollable(ScrollDirection.Vertical).enableScrollInteraction(false).scrollBar(BarState.Off)
          .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.PARENT_FIRST })
          .edgeEffect(EdgeEffect.None).align(Alignment.TopStart).opacity(this.expanded ? 1 : 0)
          .transition(TransitionEffect.OPACITY.animation({ duration: 220 }))
          .accessibilityLevel(this.expanded ? 'auto' : 'no-hide-descendants')
      }
    }.width('100%').padding(16).backgroundColor(UiColor.taskCard).borderRadius(18)
  }
}
