// 聚焦只在输入控件挂载后的布局帧执行；过期请求不得影响新输入或已离开的页面。
export class TaskInlineFocus {
  private pendingKey: string = ''
  private generation: number = 0
  private mounted: Set<string> = new Set<string>()
  private disposed: boolean = false
  private schedule: (callback: () => void) => void
  private focus: (key: string) => void

  constructor(schedule: (callback: () => void) => void, focus: (key: string) => void) {
    this.schedule = schedule
    this.focus = focus
  }
  request(key: string) {
    if (this.disposed) return
    this.pendingKey = key
    ++this.generation
    this.enqueue(key)
  }
  appeared(key: string) {
    if (this.disposed) return
    this.mounted.add(key)
    this.visible(key)
  }
  disappeared(key: string) {
    this.mounted.delete(key)
    if (this.pendingKey === key) ++this.generation
  }
  visible(key: string) {
    if (!this.disposed && this.pendingKey === key) this.enqueue(key)
  }
  cancel() { this.pendingKey = ''; ++this.generation }
  dispose() { this.cancel(); this.mounted.clear(); this.disposed = true }

  private enqueue(key: string) {
    const generation = this.generation
    try {
      this.schedule(() => {
        if (this.disposed || this.generation !== generation || this.pendingKey !== key || !this.mounted.has(key)) return
        try {
          this.focus(key)
          this.pendingKey = ''
        } catch (_) {
          // 布局期间可能暂不可见；保留输入行，待可见回调重试或由用户点选。
          console.warn('清单输入框暂不可聚焦，保留输入内容')
        }
      })
    } catch (_) {
      console.warn('清单输入聚焦已取消')
    }
  }
}
