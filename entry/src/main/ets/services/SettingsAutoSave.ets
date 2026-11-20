export type SettingsSaveKey = 'reminder' | 'reminderDuration' | 'trash'

// 同类输入只保存最新值；已开始的写入串行完成，失败后仍可继续保存。
export class SettingsAutoSave {
  private pending: Map<SettingsSaveKey, () => Promise<void>> = new Map()
  private timer: number = -1
  private running: Promise<void> | undefined = undefined
  private failed: (error: Error) => void

  constructor(failed: (error: Error) => void) { this.failed = failed }
  hasPending(): boolean { return this.pending.size > 0 || this.running !== undefined }
  schedule(key: SettingsSaveKey, save: () => Promise<void>, delay: number = 300): void {
    this.pending.set(key, save)
    if (this.timer !== -1) clearTimeout(this.timer)
    this.timer = -1
    if (delay === 0) { this.flush(); return }
    this.timer = setTimeout((): void => { this.timer = -1; this.flush() }, delay)
  }
  flush(): Promise<void> {
    if (this.timer !== -1) clearTimeout(this.timer)
    this.timer = -1
    if (!this.running && !this.pending.size) return Promise.resolve()
    if (!this.running) {
      this.running = this.drain().finally((): void => { this.running = undefined; if (this.pending.size) this.flush() })
    }
    return this.running
  }
  private async drain(): Promise<void> {
    while (this.pending.size) {
      const key = Array.from(this.pending.keys())[0]
      const save = this.pending.get(key)!
      this.pending.delete(key)
      try { await save() } catch (error) { this.failed(error as Error) }
    }
  }
}
