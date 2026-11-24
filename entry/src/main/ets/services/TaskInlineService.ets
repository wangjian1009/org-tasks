export class TaskInlineMissingError extends Error {
  constructor() { super('任务已删除或改名，请返回列表重新打开') }
}

// 当前窗口只保留一个展开编辑会话；列表重排推迟到会话结束，卡片快照与通知继续刷新。
export class TaskInlineSession {
  private static owner: string = ''
  private static finish: ((collapse: boolean) => Promise<boolean>) | undefined = undefined

  static async begin(key: string, finish: (collapse: boolean) => Promise<boolean>): Promise<boolean> {
    if (TaskInlineSession.owner && TaskInlineSession.owner !== key && !await TaskInlineSession.end(true)) return false
    TaskInlineSession.owner = key
    TaskInlineSession.finish = finish
    AppStorage.setOrCreate('taskInlineActive', key)
    return true
  }

  static async end(collapse: boolean): Promise<boolean> {
    return TaskInlineSession.finish ? await TaskInlineSession.finish(collapse) : true
  }

  static release(key: string) {
    if (TaskInlineSession.owner !== key) return
    TaskInlineSession.owner = ''
    TaskInlineSession.finish = undefined
    AppStorage.setOrCreate('taskInlineTyping', false)
    AppStorage.setOrCreate('taskInlineActive', '')
  }

  static active(): boolean { return TaskInlineSession.owner.length > 0 }
  static owns(key: string): boolean { return key.length > 0 && TaskInlineSession.owner === key }
}
