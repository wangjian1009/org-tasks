import { CoreTask } from '../services/NativeCoreService'
import { UiColor, UiSize } from '../ui/Theme'
import { taskDateIsToday, taskDateText, taskDeadlineColor, taskDeadlineText, taskDisplayDate,
  taskDurationDays, taskIndicators, taskRowLayout, taskTagColor,
  TaskRowLayout, taskTitleText } from '../ui/TaskListPresentation'
import { TitleText } from './TitleText'
import { TitleCounts } from './TitleCounts'
import { titleCounts, titleCountsWidth } from '../ui/TitleCountPresentation'
import { OrgContentView } from './OrgContentView'

// 只维护展开状态与展示；任务快照只读，导航行为由调用方提供。
@Component
export struct TaskListItem {
  @Prop task: CoreTask
  @Prop enableCompletionState: boolean = true
  @Prop showDate: boolean = false
  @Prop showCategory: boolean = false
  @Prop enableSwipeActions: boolean = false
  open: () => void = () => {}
  swipe: (left: boolean) => void = () => {}
  @State expanded: boolean = false
  @State contentMounted: boolean = false
  @State contentHeight: number = 0
  @State rowWidth: number = 366
  @State deadlineWidth: number = 0
  @Prop referenceTime: number = Date.now()
  private measuredContentHeight: number = 0

  duration(): number { return taskDurationDays(this.task, new Date(this.referenceTime)) }

  leadingDate(): string { return taskDateText(taskDisplayDate(this.task), true, new Date(this.referenceTime)) }

  leadingWidth(): number {
    return (this.showDate && taskDisplayDate(this.task).length > 0 ? this.leadingDate().length * 7 + 18 : 0)
      + (this.task.isRepeating ? 28 : 0)
  }

  deadlineColor(): string { return taskDeadlineColor(this.task, new Date(this.referenceTime)) }

  deadlineIcon(): Resource {
    return this.deadlineColor() === UiColor.deadline
      ? $r('app.media.ui_task_deadline') : $r('app.media.ui_task_deadline_neutral')
  }

  countBudget(): number {
    return Math.max(14, Math.min(140, this.rowWidth - this.deadlineWidth - this.leadingWidth() - 126))
  }

  layout(): TaskRowLayout {
    return taskRowLayout(this.rowWidth - 16 - this.leadingWidth(), this.task.tags.length, taskIndicators(this.task).length,
      this.duration(), this.task.deadline.length > 0 ? this.deadlineWidth : 0,
      titleCountsWidth(this.task.headingParts, this.countBudget()))
  }

  titleWidth(): number { return Math.max(40, this.rowWidth - 88) }

  toggle() {
    this.referenceTime = Date.now()
    this.contentMounted = true
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => {
      this.expanded = !this.expanded
      this.contentHeight = this.expanded ? this.measuredContentHeight : 0
    })
  }

  measureContent(area: Area) {
    const height = Math.ceil(parseFloat(area.height.toString()))
    if (!Number.isFinite(height) || height <= 0 || height === this.measuredContentHeight) return
    this.measuredContentHeight = height
    if (this.expanded) {
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => { this.contentHeight = height })
    }
  }

  indicatorIcon(kind: string): Resource {
    switch (kind) {
      case 'list': return $r('app.media.ui_task_list')
      default: return $r('app.media.ui_task_body')
    }
  }

  @Builder
  completionState() {
    if (this.task.todoKind === 'done' && !this.task.isCancelled) {
      Image($r('app.media.ui_task_done')).width(18).height(18)
        .accessibilityText('已完成，只读')
    } else {
      Text(this.task.isCancelled ? '−' : '').width(18).height(18).fontSize(13)
        .textAlign(TextAlign.Center).fontColor(UiColor.disabled)
        .border({ width: 1.4, color: '#8B8986' }).borderRadius(4)
        .accessibilityText(this.task.isCancelled ? '已取消，只读' : '未完成，只读')
    }
  }

  @Builder
  stateIndicator() {
    if (this.task.todoKind === null) {
      Image($r('app.media.ui_note')).width(18).height(18)
        .accessibilityText('笔记，无任务状态')
    } else {
      this.completionState()
    }
  }

  @Builder
  compactTags() {
    Row({ space: 4 }) {
      Text(this.task.tags[0]).fontSize(11).fontColor('#F5F5F5').maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .backgroundColor(taskTagColor(this.task.tags[0])).borderRadius(10)
        .constraintSize({ maxWidth: this.layout().firstTagWidth }).flexShrink(0)
      if (this.layout().showMoreTags) {
        Text('…').fontSize(12).fontColor(UiColor.secondary).width(22).height(21).textAlign(TextAlign.Center)
          .border({ width: 1, color: '#686561' }).borderRadius(10)
      }
    }.constraintSize({ maxWidth: this.layout().tagWidth }).alignItems(VerticalAlign.Center).flexShrink(0)
      .accessibilityText(`标签：${this.task.tags.join('、')}`)
      .onClick((): void => { this.toggle() })
  }

  @Builder
  compactIndicators() {
    Row({ space: 4 }) {
      if (this.layout().showAllIndicators) {
        ForEach(taskIndicators(this.task), (kind: string) => {
          Image(this.indicatorIcon(kind)).width(14).height(14)
        }, (kind: string) => kind)
      } else {
        Text('…').fontSize(13).fontColor(UiColor.secondary).width(14).maxLines(1)
      }
    }.width(this.layout().indicatorWidth).alignItems(VerticalAlign.Center).flexShrink(0)
      .accessibilityText(`${this.task.hasText ? '有正文；' : ''}${this.task.hasList ? '有列表' : ''}`)
  }

  @Builder
  compactTitle() {
    Row({ space: 6 }) {
      Column({ space: 2 }) {
        TitleText({ text: this.task.heading, parts: this.task.headingParts, lineLimit: 1, showCounts: false, cancelled: this.task.isCancelled })
          .width('100%').constraintSize({ minWidth: 0 })
        if (this.showCategory && this.task.category) {
          Text(this.task.category).fontSize(12).fontColor(UiColor.secondary).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
      }.layoutWeight(1).constraintSize({ minHeight: UiSize.taskRow }).justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Start)
        .onClick((): void => { this.toggle() })
      if (titleCounts(this.task.headingParts).length > 0) {
        TitleCounts({ parts: this.task.headingParts, budget: this.countBudget() })
          .width(titleCountsWidth(this.task.headingParts, this.countBudget())).flexShrink(0)
          .onClick((): void => { this.toggle() })
      }
      if (this.task.tags.length > 0 && this.layout().tagWidth > 0) { this.compactTags() }
      if (this.layout().indicatorWidth > 0) { this.compactIndicators() }
      if (this.layout().durationWidth > 0) {
        Text(`${this.duration()}天`).fontSize(11).fontColor(UiColor.secondary)
          .width(this.layout().durationWidth).flexShrink(0).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .accessibilityText(`持续 ${this.duration()} 天`)
      }
    }.layoutWeight(1).constraintSize({ minWidth: 0, minHeight: UiSize.taskRow }).alignItems(VerticalAlign.Center)
      .accessibilityText(`${taskTitleText(this.task)}，点击展开`)
  }

  @Builder
  expandedTitle() {
    Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
      TitleText({ text: this.task.heading, parts: this.task.headingParts, showCounts: false, cancelled: this.task.isCancelled })
        .constraintSize({ maxWidth: this.titleWidth() }).margin({ right: 8, bottom: 6 })
      if (titleCounts(this.task.headingParts).length > 0) {
        TitleCounts({ parts: this.task.headingParts }).width(this.titleWidth()).margin({ bottom: 6 })
      }
      ForEach(this.task.tags, (tag: string) => {
        Text(tag).fontSize(13).fontColor('#F5F5F5').wordBreak(WordBreak.BREAK_ALL)
          .padding({ left: 10, right: 10, top: 3, bottom: 3 }).backgroundColor(taskTagColor(tag)).borderRadius(13)
          .constraintSize({ maxWidth: this.titleWidth() }).margin({ right: 6, bottom: 6 })
          .onClick((): void => { this.toggle() })
      }, (tag: string) => tag)
    }.layoutWeight(1).constraintSize({ minWidth: 0, minHeight: 32 })
      .accessibilityText(`${taskTitleText(this.task)}，点击收起`)
      .onClick((): void => { this.toggle() })
  }

  @Builder
  compactDeadline() {
    Row({ space: 4 }) {
      Image(this.deadlineIcon()).width(16).height(16)
      Text(taskDeadlineText(this.task, new Date(this.referenceTime))).fontSize(12).fontColor(this.deadlineColor())
        .maxLines(1).flexShrink(0)
    }.alignItems(VerticalAlign.Center).flexShrink(0)
      .onAreaChange((oldArea: Area, newArea: Area) => {
        const width = parseFloat(newArea.width.toString())
        if (Number.isFinite(width) && width > 0 && width !== this.deadlineWidth) this.deadlineWidth = width
      })
      .accessibilityText(`截止日期：${taskDateText(this.task.deadline, false, new Date(this.referenceTime))}`)
  }

  @Builder
  compactLeadingInfo() {
    if (this.showDate && taskDisplayDate(this.task).length > 0) {
      Text(this.leadingDate()).fontSize(11).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
        .backgroundColor('#5A5856').borderRadius(3).padding({ left: 5, right: 5, top: 2, bottom: 2 })
        .maxLines(1).flexShrink(0)
        .accessibilityText(`日期：${taskDateText(taskDisplayDate(this.task), false, new Date(this.referenceTime))}`)
    }
    if (this.task.isRepeating) {
      Image($r('app.media.ui_task_repeat')).width(20).height(20).flexShrink(0)
        .accessibilityText('重复任务')
    }
  }

  @Builder
  detailsButton() {
    Button({ type: ButtonType.Normal }) {
      Image($r('app.media.ui_task_details')).width(20).height(20).padding(6).width(32).height(32)
        .backgroundColor('#494846').borderRadius(9)
    }.width(44).height(44).borderRadius(12).backgroundColor(Color.Transparent)
      .flexShrink(0).accessibilityText('查看任务详情').onClick((): void => { this.open() })
  }

  @Builder
  scheduledInfo() {
    Row({ space: 8 }) {
      Image(taskDateIsToday(this.task.scheduled, new Date(this.referenceTime))
        ? $r('app.media.nav_today') : $r('app.media.ui_task_calendar')).width(22).height(22).flexShrink(0)
      Text(taskDateIsToday(this.task.scheduled, new Date(this.referenceTime))
        ? '今天' : taskDateText(this.task.scheduled, false, new Date(this.referenceTime)))
        .fontSize(15).fontColor(UiColor.text).layoutWeight(1).wordBreak(WordBreak.BREAK_ALL)
    }.padding(taskDateIsToday(this.task.scheduled, new Date(this.referenceTime)) ? 0 : 7)
      .border({ width: taskDateIsToday(this.task.scheduled, new Date(this.referenceTime)) ? 0 : 1, color: '#706D69' })
      .borderRadius(10).constraintSize({ maxWidth: this.rowWidth - 140 }).flexShrink(1)
      .accessibilityText(`计划日期：${taskDateText(this.task.scheduled, false, new Date(this.referenceTime))}`)
  }

  @Builder
  expandedContent() {
    Column({ space: 10 }) {
      if (this.duration() > 0) {
        Text(`持续 ${this.duration()} 天`).fontSize(12).fontColor(UiColor.secondary).width('100%')
      }
      if (this.task.bodyHtml.trim().length > 0) {
        OrgContentView({ fragment: this.task.bodyHtml, embedded: true,
          contentBackground: UiColor.taskCard, embeddedPadding: 0, horizontalParentFirst: this.enableSwipeActions,
          horizontalSwipe: (left: boolean): void => { this.swipe(left) } }).width('100%')
      }
      if (this.task.scheduled.length > 0) {
        Row() {
          this.scheduledInfo()
          Blank().layoutWeight(1)
          if (this.task.deadline.length === 0) { this.detailsButton() }
        }.width('100%').constraintSize({ minHeight: UiSize.taskRow })
      }
      if (this.task.deadline.length > 0) {
        Row({ space: 6 }) {
          Image(this.deadlineIcon()).width(18).height(18)
            .flexShrink(0).align(Alignment.Top)
          Column({ space: 2 }) {
            Text(`截止日期：${taskDateText(this.task.deadline, false, new Date(this.referenceTime))}`)
              .fontSize(14).fontColor(this.deadlineColor()).width('100%').wordBreak(WordBreak.BREAK_ALL)
            if (taskDateIsToday(this.task.deadline, new Date(this.referenceTime))) {
              Text('今天').fontSize(12).fontColor(UiColor.secondary).width('100%')
            }
          }.layoutWeight(1)
          this.detailsButton()
        }.width('100%').constraintSize({ minHeight: UiSize.taskRow })
      } else if (this.task.scheduled.length === 0) {
        Row() { Blank().layoutWeight(1); this.detailsButton() }.width('100%')
      }
    }.width('100%').padding({ left: 28, top: 8 }).alignItems(HorizontalAlign.Start).flexShrink(0)
      .onAreaChange((oldArea: Area, newArea: Area) => { this.measureContent(newArea) })
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        this.stateIndicator()
        if (this.expanded) {
          this.expandedTitle()
          Image($r('app.media.ui_up')).width(20).height(20).flexShrink(0)
            .accessibilityText('收起任务').onClick((): void => { this.toggle() })
        } else {
          this.compactLeadingInfo()
          this.compactTitle()
          if (this.task.deadline.length > 0) { this.compactDeadline() }
        }
      }.width('100%').alignItems(this.expanded ? VerticalAlign.Top : VerticalAlign.Center)
      if (this.contentMounted) {
        // 仅用于内容测量与动画裁切，纵向滚动交给外层列表。
        Scroll() { this.expandedContent() }.width('100%').height(this.contentHeight).clip(true)
          .scrollable(ScrollDirection.Vertical).enableScrollInteraction(false).scrollBar(BarState.Off)
          .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.PARENT_FIRST })
          .edgeEffect(EdgeEffect.None).align(Alignment.TopStart)
          .opacity(this.expanded ? 1 : 0)
          .transition(TransitionEffect.OPACITY.animation({ duration: 220 }))
          .accessibilityLevel(this.expanded ? 'auto' : 'no-hide-descendants')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: this.expanded ? 16 : 8, right: this.expanded ? 16 : 8,
        top: this.expanded ? 16 : 0, bottom: this.expanded ? 16 : 0 })
      .margin({ top: this.expanded ? 8 : 0, bottom: this.expanded ? 8 : 0 })
      .backgroundColor(this.expanded ? UiColor.taskCard : Color.Transparent).borderRadius(18)
      .onAreaChange((oldArea: Area, newArea: Area) => {
        const width = parseFloat(newArea.width.toString())
        if (Number.isFinite(width) && width > 0 && width !== this.rowWidth) this.rowWidth = width
      })
  }
}
