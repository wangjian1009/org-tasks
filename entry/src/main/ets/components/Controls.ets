import { UiColor } from '../ui/Theme'
import { CoreTask } from '../services/NativeCoreService'

@Component
export struct IconButton {
  @Prop icon: Resource = $r('app.media.ui_more')
  @Prop label: string = ''
  @Prop disabled: boolean = false
  action: () => void = () => {}

  build() {
    Button({ type: ButtonType.Normal }) {
      Image(this.icon).width(24).height(24)
    }
    .width(48).height(48).borderRadius(24).backgroundColor(Color.Transparent)
    .accessibilityText(this.label).enabled(!this.disabled).onClick((): void => { this.action() })
  }
}

@Component
export struct EmptyState {
  @Prop title: string = ''
  @Prop detail: string = ''
  @Prop actionLabel: string = ''
  @Prop busy: boolean = false
  action: () => void = () => {}

  build() {
    Column({ space: 12 }) {
      if (this.busy) {
        LoadingProgress().width(32).height(32).color(UiColor.primary)
      }
      Text(this.title).fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
      Text(this.detail).fontSize(14).fontColor(UiColor.secondary).textAlign(TextAlign.Center).lineHeight(22)
      if (this.actionLabel.length > 0) {
        Button(this.actionLabel).backgroundColor(UiColor.selected).fontColor(UiColor.onSelected)
          .margin({ top: 8 }).onClick((): void => { this.action() })
      }
    }
    .width('100%').height('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding(32)
  }
}

@Component
export struct MessageBar {
  @Prop message: string = ''
  @Prop error: boolean = false

  build() {
    if (this.message.length > 0) {
      Text(this.message).width('100%').padding(16).fontSize(13).lineHeight(20)
        .fontColor(this.error ? UiColor.error : UiColor.secondary).backgroundColor(UiColor.container)
        .accessibilityLevel('yes')
    }
  }
}

@Component
export struct SectionHeading {
  @Prop title: string = ''
  @Prop subtitle: string = ''

  build() {
    Column({ space: 4 }) {
      Text(this.title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiColor.primary).width('100%')
      if (this.subtitle.length > 0) {
        Text(this.subtitle).fontSize(12).fontColor(UiColor.secondary).width('100%')
      }
    }.width('100%').padding({ left: 16, right: 16, top: 24, bottom: 12 })
  }
}

@Component
export struct TaskRow {
  @Prop task: CoreTask
  @Prop showSource: boolean = true
  @Prop showBody: boolean = false
  @Prop indent: number = 0
  @Prop canFold: boolean = false
  @Prop folded: boolean = false
  open: () => void = () => {}
  fold: () => void = () => {}

  build() {
    Row({ space: 8 }) {
      if (!this.showSource) {
        Button({ type: ButtonType.Normal }) {
          Text(this.canFold ? (this.folded ? '▸' : '▾') : '•').fontSize(18).fontColor(UiColor.secondary)
        }.width(40).height(48).backgroundColor(Color.Transparent).borderRadius(20)
          .enabled(this.canFold).accessibilityText(this.folded ? '展开子笔记' : '收起子笔记').onClick((): void => { this.fold() })
      }
      Column({ space: 5 }) {
        Row({ space: 6 }) {
          if (this.task.todoState.length > 0) {
            Text(this.task.todoState).fontSize(13).fontWeight(FontWeight.Medium)
              .fontColor(this.task.todoState === 'DONE' || this.task.todoState === 'CNCL' ? UiColor.done : UiColor.error)
          }
          if (this.task.priority.length > 0) {
            Text(`[#${this.task.priority}]`).fontSize(13).fontColor(UiColor.secondary)
          }
          Text(this.task.heading).fontSize(16).fontColor(UiColor.text).layoutWeight(1).maxLines(3)
        }.width('100%').alignItems(VerticalAlign.Top)
        if (this.showBody && this.task.body.trim().length > 0) {
          Text(this.task.body.trim()).fontSize(14).fontColor(UiColor.secondary).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
        if (this.showSource) {
          Row({ space: 6 }) {
            Image($r('app.media.ui_folder')).width(14).height(14)
            Text(this.task.filePath).fontSize(13).fontColor(UiColor.secondary).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          }.width('100%')
        }
        if (this.task.scheduled.length > 0 || this.task.deadline.length > 0) {
          Row({ space: 6 }) {
            Image(this.task.deadline.length > 0 ? $r('app.media.ui_deadline') : $r('app.media.ui_calendar'))
              .width(14).height(14)
            Text(`${this.task.scheduled ? `计划 ${this.task.scheduled}` : ''}${this.task.scheduled && this.task.deadline ? ' · ' : ''}${this.task.deadline ? `截止 ${this.task.deadline}` : ''}`)
              .fontSize(13).fontColor(UiColor.secondary).layoutWeight(1)
          }.width('100%')
        }
        if (this.task.tags.length > 0) {
          Text(this.task.tags.join('  ')).fontSize(12).fontColor(UiColor.primary).maxLines(1).width('100%')
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start).onClick((): void => { this.open() })
    }
    .width('100%').padding({ left: 16 + this.indent, right: 16, top: 12, bottom: 12 })
    .border({ width: { bottom: 0.5 }, color: UiColor.outline })
  }
}

@Component
export struct PreferenceRow {
  @Prop title: string = ''
  @Prop detail: string = ''
  @Prop icon: Resource = $r('app.media.ui_settings')
  action: () => void = () => {}

  build() {
    Row({ space: 24 }) {
      Image(this.icon).width(24).height(24)
      Column({ space: 5 }) {
        Text(this.title).fontSize(16).fontColor(UiColor.text).width('100%')
        if (this.detail.length > 0) {
          Text(this.detail).fontSize(13).fontColor(UiColor.secondary).width('100%').lineHeight(20)
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Image($r('app.media.ui_next')).width(18).height(18)
    }.width('100%').padding({ left: 20, right: 20, top: 18, bottom: 18 }).onClick((): void => { this.action() })
  }
}
