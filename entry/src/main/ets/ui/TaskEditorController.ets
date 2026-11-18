import { CoreTaskOperationGroup, CoreRefileTarget, CoreTaskPlanningEdit } from '../services/NativeCoreService'

// 编辑器提供具体操作接口；手势宿主负责把 Action 映射到这些接口。
export interface TaskEditorActions {
  actionsAvailable(): boolean
  deletionAvailable(): boolean
  moveTo(target: CoreRefileTarget, allowed?: () => boolean): Promise<CoreTaskOperationGroup | undefined>
  setSchedule(value: CoreTaskPlanningEdit | null, allowed?: () => boolean): Promise<CoreTaskOperationGroup | undefined>
  setDeadline(value: CoreTaskPlanningEdit | null, allowed?: () => boolean): Promise<CoreTaskOperationGroup | undefined>
  remove(allowed?: () => boolean, expectedVersion?: string): Promise<CoreTaskOperationGroup | undefined>
  startNote(allowed?: () => boolean): Promise<CoreTaskOperationGroup | undefined>
  startMove(allowed?: () => boolean): Promise<CoreTaskOperationGroup | undefined>
  startSchedule(allowed?: () => boolean): Promise<CoreTaskOperationGroup | undefined>
  startDeadline(allowed?: () => boolean): Promise<CoreTaskOperationGroup | undefined>
  startDelete(allowed?: () => boolean): Promise<CoreTaskOperationGroup | undefined>
  start(allowed?: () => boolean): Promise<CoreTaskOperationGroup | undefined>
  wait(allowed?: () => boolean): Promise<CoreTaskOperationGroup | undefined>
  stop(allowed?: () => boolean): Promise<CoreTaskOperationGroup | undefined>
  moveToSomeday(allowed?: () => boolean): Promise<CoreTaskOperationGroup | undefined>
  convertToMemo(allowed?: () => boolean): Promise<CoreTaskOperationGroup | undefined>
}

export class TaskEditorController {
  private editor: TaskEditorActions | undefined = undefined
  private listener: ((group: CoreTaskOperationGroup) => void) | undefined

  constructor(listener?: (group: CoreTaskOperationGroup) => void) { this.listener = listener }

  emitOperation(group: CoreTaskOperationGroup): void {
    if (!this.listener) throw new Error('未提供修改操作接收接口')
    this.listener(group)
  }

  bind(editor: TaskEditorActions): void { this.editor = editor }
  canActivate(): boolean { return this.editor?.actionsAvailable() ?? false }
  canDelete(): boolean { return this.editor?.deletionAvailable() ?? false }
  isBound(): boolean { return this.editor !== undefined }

  async startNote(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    if (allowed() && this.canActivate()) return await this.editor?.startNote(allowed)
    return undefined
  }
  async startMove(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    if (allowed() && this.canActivate()) return await this.editor?.startMove(allowed)
    return undefined
  }
  async startSchedule(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    if (allowed() && this.canActivate()) return await this.editor?.startSchedule(allowed)
    return undefined
  }
  async startDeadline(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    if (allowed() && this.canActivate()) return await this.editor?.startDeadline(allowed)
    return undefined
  }
  async startDelete(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    if (allowed() && this.canDelete()) return await this.editor?.startDelete(allowed)
    return undefined
  }
  async start(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    if (allowed() && this.canActivate()) return await this.editor?.start(allowed)
    return undefined
  }
  async stop(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    if (allowed() && this.canActivate()) return await this.editor?.stop(allowed)
    return undefined
  }
  async wait(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    if (allowed() && this.canActivate()) return await this.editor?.wait(allowed)
    return undefined
  }
  async moveToSomeday(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    if (allowed() && this.canActivate()) return await this.editor?.moveToSomeday(allowed)
    return undefined
  }
  async convertToMemo(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    if (allowed() && this.canActivate()) return await this.editor?.convertToMemo(allowed)
    return undefined
  }
  async moveTo(target: CoreRefileTarget, allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    if (allowed() && this.canActivate()) return await this.editor?.moveTo(target, allowed)
    return undefined
  }
  async setSchedule(value: CoreTaskPlanningEdit | null, allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    if (allowed() && this.canActivate()) return await this.editor?.setSchedule(value, allowed)
    return undefined
  }
  async setDeadline(value: CoreTaskPlanningEdit | null, allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    if (allowed() && this.canActivate()) return await this.editor?.setDeadline(value, allowed)
    return undefined
  }
  async remove(allowed: () => boolean = () => true, expectedVersion?: string): Promise<CoreTaskOperationGroup | undefined> {
    if (allowed() && this.canDelete()) return await this.editor?.remove(allowed, expectedVersion)
    return undefined
  }
  release(): void { this.editor = undefined }
}
