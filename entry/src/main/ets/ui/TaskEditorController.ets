// 宿主控制卡片已有编辑入口，手势与页面动作由宿主维护。
export class TaskEditorController {
  private available: () => boolean = (): boolean => false
  private schedule: () => void = (): void => {}
  private move: () => void = (): void => {}

  bind(available: () => boolean, schedule: () => void, move: () => void): void {
    this.available = available
    this.schedule = schedule
    this.move = move
  }

  canActivate(): boolean { return this.available() }

  openSchedule(): void { if (this.canActivate()) this.schedule() }
  openMove(): void { if (this.canActivate()) this.move() }

  release(): void {
    this.available = (): boolean => false
    this.schedule = (): void => {}
    this.move = (): void => {}
  }
}
