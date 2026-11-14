// 同一正文只保留一个区块草稿；离开任务、切换字段和刷新前共用保存边界。
export class TaskBlockController {
  private owner: string = ''
  private finishCurrent: (() => Promise<boolean>) | undefined = undefined
  private cancelCurrent: (() => void) | undefined = undefined
  private pending: Promise<boolean> | undefined = undefined

  async begin(owner: string, finish: () => Promise<boolean>, cancel?: () => void): Promise<boolean> {
    if (this.owner !== owner && !await this.finish()) return false
    this.owner = owner
    this.finishCurrent = finish
    this.cancelCurrent = cancel
    return true
  }

  async finish(): Promise<boolean> {
    if (this.pending) return this.pending
    const finish = this.finishCurrent
    if (!finish) return true
    this.pending = finish()
    try {
      const saved = await this.pending
      if (saved && this.finishCurrent === finish) { this.owner = ''; this.finishCurrent = undefined; this.cancelCurrent = undefined }
      return saved
    } finally { this.pending = undefined }
  }

  cancel() {
    const cancel = this.cancelCurrent
    this.owner = ''; this.finishCurrent = undefined; this.cancelCurrent = undefined
    cancel?.()
  }

  release(owner: string) {
    if (this.owner !== owner) return
    this.owner = ''; this.finishCurrent = undefined; this.cancelCurrent = undefined
  }
}
