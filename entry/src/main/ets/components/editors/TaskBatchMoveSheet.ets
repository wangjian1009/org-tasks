import { TaskSelectionController } from '../../ui/TaskSelectionController'
import { TaskOperation } from '../../ui/TaskActionPresentation'
import { CoreRefileTarget, CoreBridgeError, coreErrorMessage } from '../../services/NativeCoreService'
import { RefileSection, refileSections } from '../../ui/MoveToTargetPresentation'
import { MoveToTarget } from './MoveToTarget'

// 面板自行读取目标并管理异步会话；所选源快照和提交由选择控制器持有。
@Component
export struct TaskBatchMoveSheet {
  @ObjectLink selection: TaskSelectionController
  @State open: boolean = false
  @State loading: boolean = false
  @State sections: RefileSection[] = []
  @State message: string = ''
  private token: number = -1
  private active: boolean = false

  aboutToAppear(): void {
    this.active = true; this.token = this.selection.popupToken(); this.open = true
    this.load()
  }
  aboutToDisappear(): void { this.active = false; this.open = false }
  valid(): boolean { return this.active && this.selection.popupAvailable(TaskOperation.Move, this.token) }
  dismiss(): void { if (this.token === this.selection.popupToken() && !this.selection.busy) this.selection.cancelPopup() }

  async load(): Promise<void> {
    if (!this.valid() || this.loading) return
    this.loading = true; this.message = ''
    try {
      const targets = await this.selection.moveTargets()
      if (this.valid()) this.sections = refileSections(targets)
    } catch (error) { if (this.valid()) this.message = coreErrorMessage(error as CoreBridgeError) }
    finally { if (this.active) this.loading = false }
  }

  @Builder
  panel() {
    MoveToTarget({ sections: this.sections, selectionKey: `${this.token}`,
      loading: this.loading, busy: this.selection.busy, message: this.message || this.selection.message,
      choose: (target: CoreRefileTarget): void => {
        if (this.valid()) this.selection.execute(this.getUIContext(), TaskOperation.Move, target)
      },
      retry: (): void => {
        if (this.selection.message) this.selection.reset()
        else this.load()
      } })
  }

  build() {
    Column().width(0).height(0)
      .bindSheet($$this.open, this.panel, {
        height: '70%', detents: ['70%', '90%'], preferType: SheetType.BOTTOM,
        backgroundColor: '#363A38', showClose: true,
        onWillDismiss: (action): void => {
          if (!this.selection.busy) { action.dismiss(); this.dismiss() }
        },
        onDisappear: (): void => { this.dismiss() }
      })
  }
}
