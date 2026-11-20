export class SwipeMenuCoordinator {
  private current: (() => void) | undefined = undefined

  show(close: () => void): void {
    if (close === this.current) return
    this.close()
    this.current = close
  }

  forget(close: () => void): void { if (close === this.current) this.current = undefined }

  close(): boolean {
    const close = this.current
    this.current = undefined
    close?.()
    return close !== undefined
  }
}

// 只负责整块内容的拖动与回弹，业务动作由宿主传入并在回弹完成后执行。
@Component
export struct RightSwipe {
  @BuilderParam content: () => void = this.emptyContent
  @BuilderParam endMenu: (close: () => void) => void = this.emptyMenu
  @Prop disabled: boolean = false
  @Prop @Watch('menuChanged') menuWidth: number = 0
  menuCoordinator: SwipeMenuCoordinator | undefined = undefined
  canOpenMenu: () => boolean = (): boolean => true
  canActivate: () => boolean = (): boolean => true
  action: () => void = () => {}
  @State private dragOffset: number = 0
  @State private menuOpen: boolean = false
  @State private contentHeight: number = 0
  private contentWidth: number = 0
  private returning: boolean = false
  private active: boolean = false
  private generation: number = 0
  private closeMenu: () => void = (): void => { this.hideMenu() }
  private beganOpen: boolean = false

  @Builder
  emptyContent() {}

  @Builder
  emptyMenu(_close: () => void) {}

  aboutToAppear(): void { this.active = true }
  aboutToDisappear(): void {
    this.active = false
    ++this.generation
    this.menuCoordinator?.forget(this.closeMenu)
  }

  private start(offsetX: number): void {
    this.beganOpen = this.menuOpen
    if (!this.beganOpen) this.menuCoordinator?.close()
    this.drag(offsetX)
  }

  private drag(offsetX: number): void {
    if (this.returning) return
    if (this.beganOpen) {
      this.dragOffset = Math.max(-this.menuWidth, Math.min(0, offsetX - this.menuWidth))
    } else if (offsetX < 0 && this.menuWidth > 0 && this.canOpenMenu()) {
      this.menuCoordinator?.show(this.closeMenu)
      this.dragOffset = Math.max(-this.menuWidth, offsetX)
    } else {
      this.dragOffset = this.disabled ? 0 : Math.max(0, Math.min(offsetX, this.contentWidth * 0.75))
    }
  }

  private release(offsetX: number): void {
    if (this.returning) return
    this.drag(offsetX)
    if (this.beganOpen || this.dragOffset < 0) {
      if ((this.beganOpen ? offsetX <= 24 : offsetX < -32) && this.menuWidth > 0 && this.canOpenMenu()) {
        this.menuOpen = true
        this.getUIContext().animateTo({ duration: 150, curve: Curve.EaseOut }, (): void => { this.dragOffset = -this.menuWidth })
      } else this.hideMenu()
    } else {
      this.menuCoordinator?.forget(this.closeMenu)
      this.rebound(offsetX > 48)
    }
  }

  private hideMenu(): void {
    this.menuCoordinator?.forget(this.closeMenu)
    if (!this.menuOpen && this.dragOffset >= 0) return
    this.menuOpen = false
    this.beganOpen = false
    this.rebound(false)
  }

  private menuChanged(): void {
    if (this.menuWidth === 0) this.hideMenu()
    else if (this.menuOpen) this.dragOffset = -this.menuWidth
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
        if (trigger && !this.disabled && this.canActivate()) this.action()
      }
    }, (): void => { this.dragOffset = 0 })
  }

  build() {
    Stack({ alignContent: Alignment.End }) {
      Column() { this.content() }
        .width('100%').translate({ x: this.dragOffset })
      if (this.menuOpen) {
        Row().width('100%').height(this.contentHeight).translate({ x: this.dragOffset })
          .accessibilityLevel('no').onClick((): void => { this.hideMenu() })
      }
      if (this.menuWidth > 0 && (this.menuOpen || this.dragOffset < 0)) {
        Row() { this.endMenu(this.closeMenu) }
          .width(this.menuWidth).height(this.contentHeight)
          .translate({ x: this.menuWidth + Math.min(0, this.dragOffset) })
      }
    }.width('100%').clip(true)
      .onAreaChange((_old: Area, area: Area): void => {
        this.contentWidth = Number(area.width)
        if (this.menuCoordinator) this.contentHeight = Number(area.height)
      })
      .priorityGesture(PanGesture({ direction: this.menuCoordinator ? PanDirection.Horizontal : PanDirection.Right, distance: 8 })
        .tag('shared_right_swipe')
        .onActionStart((event: GestureEvent): void => { this.start(event.offsetX) })
        .onActionUpdate((event: GestureEvent): void => { this.drag(event.offsetX) })
        .onActionEnd((event: GestureEvent): void => { this.release(event.offsetX) })
        .onActionCancel((): void => { if (this.dragOffset < 0 || this.menuOpen) this.hideMenu(); else this.rebound(false) }))
      .onGestureJudgeBegin((info: GestureInfo) => info.tag === 'shared_right_swipe' && (this.returning ||
        ((this.disabled || !this.canActivate()) && !(this.menuWidth > 0 && this.canOpenMenu()))) ? GestureJudgeResult.REJECT : GestureJudgeResult.CONTINUE)
  }
}
