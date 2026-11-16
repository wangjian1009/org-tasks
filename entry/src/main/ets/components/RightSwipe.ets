// 只负责整块内容的拖动与回弹，业务动作由宿主传入并在回弹完成后执行。
@Component
export struct RightSwipe {
  @BuilderParam content: () => void = this.emptyContent
  @Prop disabled: boolean = false
  action: () => void = () => {}
  @State private dragOffset: number = 0
  private contentWidth: number = 0
  private returning: boolean = false
  private active: boolean = false
  private generation: number = 0

  @Builder
  emptyContent() {}

  aboutToAppear(): void { this.active = true }
  aboutToDisappear(): void { this.active = false; ++this.generation }

  private drag(offsetX: number): void {
    if (this.returning) return
    this.dragOffset = Math.max(0, Math.min(offsetX, this.contentWidth * 0.75))
  }

  private release(offsetX: number): void {
    this.drag(offsetX)
    this.rebound(offsetX > 48)
  }

  private rebound(trigger: boolean): void {
    if (this.returning) return
    if (this.dragOffset === 0) return
    this.returning = true
    const generation = ++this.generation
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut,
      onFinish: (): void => {
        if (!this.active || !this.returning || generation !== this.generation) return
        this.returning = false
        if (trigger && !this.disabled) this.action()
      }
    }, (): void => { this.dragOffset = 0 })
  }

  build() {
    Column() {
      Column() { this.content() }
        .width('100%').translate({ x: this.dragOffset })
    }.width('100%').clip(true)
      .onAreaChange((_old: Area, area: Area): void => { this.contentWidth = Number(area.width) })
      .parallelGesture(PanGesture({ direction: PanDirection.Right, distance: 8 })
        .tag('shared_right_swipe')
        .onActionStart((event: GestureEvent): void => { this.drag(event.offsetX) })
        .onActionUpdate((event: GestureEvent): void => { this.drag(event.offsetX) })
        .onActionEnd((event: GestureEvent): void => { this.release(event.offsetX) })
        .onActionCancel((): void => { this.rebound(false) }))
      .onGestureJudgeBegin((info: GestureInfo) => info.tag === 'shared_right_swipe' && (this.disabled || this.returning)
        ? GestureJudgeResult.REJECT : GestureJudgeResult.CONTINUE)
  }
}
