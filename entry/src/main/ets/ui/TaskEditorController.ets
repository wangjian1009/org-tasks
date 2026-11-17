// 编辑器提供具体操作接口；手势宿主负责把 Action 映射到这些接口。
export interface TaskEditorActions {
  actionsAvailable(): boolean
  deletionAvailable(): boolean
  startMove(allowed?: () => boolean): Promise<void>
  startSchedule(allowed?: () => boolean): Promise<void>
  startDeadline(allowed?: () => boolean): Promise<void>
  startDelete(allowed?: () => boolean): Promise<void>
  start(allowed?: () => boolean): Promise<void>
  stop(allowed?: () => boolean): Promise<void>
  moveToSomeday(allowed?: () => boolean): Promise<void>
  convertToMemo(allowed?: () => boolean): Promise<void>
}

export class TaskEditorController {
  private editor: TaskEditorActions | undefined = undefined

  bind(editor: TaskEditorActions): void { this.editor = editor }
  canActivate(): boolean { return this.editor?.actionsAvailable() ?? false }
  canDelete(): boolean { return this.editor?.deletionAvailable() ?? false }
  isBound(): boolean { return this.editor !== undefined }

  async startMove(allowed: () => boolean = () => true): Promise<void> {
    if (allowed() && this.canActivate()) await this.editor?.startMove(allowed)
  }
  async startSchedule(allowed: () => boolean = () => true): Promise<void> {
    if (allowed() && this.canActivate()) await this.editor?.startSchedule(allowed)
  }
  async startDeadline(allowed: () => boolean = () => true): Promise<void> {
    if (allowed() && this.canActivate()) await this.editor?.startDeadline(allowed)
  }
  async startDelete(allowed: () => boolean = () => true): Promise<void> {
    if (allowed() && this.canDelete()) await this.editor?.startDelete(allowed)
  }
  async start(allowed: () => boolean = () => true): Promise<void> {
    if (allowed() && this.canActivate()) await this.editor?.start(allowed)
  }
  async stop(allowed: () => boolean = () => true): Promise<void> {
    if (allowed() && this.canActivate()) await this.editor?.stop(allowed)
  }
  async moveToSomeday(allowed: () => boolean = () => true): Promise<void> {
    if (allowed() && this.canActivate()) await this.editor?.moveToSomeday(allowed)
  }
  async convertToMemo(allowed: () => boolean = () => true): Promise<void> {
    if (allowed() && this.canActivate()) await this.editor?.convertToMemo(allowed)
  }
  release(): void { this.editor = undefined }
}
