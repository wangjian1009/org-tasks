import { UiColor } from '../ui/Theme'

// 原任务内容保持挂载，多选期间由外层承接点击并屏蔽内部编辑。
@Component
export struct TaskSelectionRow {
  @Prop selecting: boolean = false
  @Prop busy: boolean = false
  @Prop selectedIndex: number = -1
  @Prop heading: string = ''
  @Prop highlighted: boolean = false
  @Prop horizontalInset: number = 0
  @BuilderParam content: () => void
  begin: () => void = () => {}
  toggle: () => void = () => {}

  selectionActive(): boolean { return this.selecting }
  beginSelection() { if (!this.selecting && !this.busy) this.begin() }
  toggleSelection() { if (this.selectionActive() && !this.busy) this.toggle() }

  build() {
    Row() {
      Column() { this.content() }.layoutWeight(1).constraintSize({ minWidth: 0 })
        .enabled(!this.selectionActive()).hitTestBehavior(this.selectionActive() ? HitTestMode.None : HitTestMode.Default)
        .accessibilityLevel(this.selectionActive() ? 'no-hide-descendants' : 'auto')
      if (this.selectionActive()) {
        Row() {
          if (this.selectedIndex >= 0) { Text(`${this.selectedIndex + 1}`).fontSize(12).fontColor(Color.White) }
        }.width(24).height(24).flexShrink(0).margin({ left: 8 }).borderRadius(12)
          .border({ width: 1.5, color: this.selectedIndex >= 0 ? UiColor.selection : UiColor.secondary })
          .backgroundColor(this.selectedIndex >= 0 ? UiColor.selection : Color.Transparent)
          .justifyContent(FlexAlign.Center).accessibilityLevel('no')
      }
    }.width('100%').padding({ left: this.horizontalInset, right: this.horizontalInset })
      .backgroundColor(this.selectionActive() ? (this.selectedIndex >= 0 ? UiColor.selectionTint : Color.Transparent) :
        this.highlighted ? '#323D3A' : Color.Transparent)
      .borderRadius(this.selectionActive() ? 8 : 12)
      .border({ width: !this.selectionActive() && this.highlighted ? 1 : 0, color: UiColor.primary })
      .accessibilityText(this.selectionActive() ? `${this.heading}，${this.selectedIndex >= 0 ? `已选择，第 ${this.selectedIndex + 1} 条` : '未选择'}` : '')
      .onClick((): void => { this.toggleSelection() })
      .gesture(LongPressGesture({ repeat: false }).onAction((): void => { this.beginSelection() }))
  }
}
