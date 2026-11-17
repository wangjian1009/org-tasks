import { CoreTaskOperationGroup } from '../services/NativeCoreService'

// 一次数据编辑会话只返回一个结果；取消和页面退出均返回 undefined。
export class TaskEditorActionResult {
  private settled: boolean = false
  private resolve: (group: CoreTaskOperationGroup | undefined) => void = () => {}
  readonly result: Promise<CoreTaskOperationGroup | undefined>

  constructor() {
    this.result = new Promise<CoreTaskOperationGroup | undefined>(resolve => { this.resolve = resolve })
  }

  finish(group?: CoreTaskOperationGroup): void {
    if (this.settled) return
    this.settled = true
    this.resolve(group)
  }
}
