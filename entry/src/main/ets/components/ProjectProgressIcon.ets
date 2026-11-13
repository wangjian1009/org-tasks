@Component
export struct ProjectProgressIcon {
  @Prop @Watch('draw') completed: number = 0
  @Prop @Watch('draw') total: number = 0
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true))
  private ready: boolean = false

  draw() {
    if (!this.ready) return
    const ratio = this.total > 0 ? Math.max(0, Math.min(1, this.completed / this.total)) : 0
    this.context.clearRect(0, 0, 22, 22)
    this.context.strokeStyle = '#89949F'
    this.context.lineWidth = 2
    this.context.beginPath()
    this.context.arc(11, 11, 9.5, 0, Math.PI * 2)
    this.context.stroke()
    if (ratio > 0) {
      // 完成比例填充圆内扇形，和外圈留出空隙，避免小比例仅表现为不易辨认的描边。
      this.context.fillStyle = '#AAB4BE'
      this.context.beginPath()
      this.context.moveTo(11, 11)
      this.context.arc(11, 11, 7, -Math.PI / 2, -Math.PI / 2 + ratio * Math.PI * 2)
      this.context.closePath()
      this.context.fill()
    }
  }

  build() {
    Canvas(this.context).width(22).height(22).accessibilityLevel('no')
      .onReady((): void => { this.ready = true; this.draw() })
  }
}
