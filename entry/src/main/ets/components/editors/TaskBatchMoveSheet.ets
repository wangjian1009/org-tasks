import { TaskSelectionController } from '../../ui/TaskSelectionController'
import { TaskOperation } from '../../ui/TaskActionPresentation'
import { CoreTask, CoreRefileTarget, CoreBridgeError, coreErrorMessage } from '../../services/NativeCoreService'
import { RefileSection, refileSections } from '../../ui/MoveToTargetPresentation'
import { MoveToTarget } from './MoveToTarget'
import { TaskMovePreview } from './TaskEditor'

// 面板自行读取目标并管理异步会话；所选源快照和提交由选择控制器持有。
@Component
export struct TaskBatchMoveSheet {
  @ObjectLink selection: TaskSelectionController
  @State open: boolean = true
  @State detent: string = '75%'
  @State sources: CoreTask[] = []
  @State loading: boolean = false
  @State sections: RefileSection[] = []
  @State repositoryNames: Map<string, string> = new Map()
  @State message: string = ''
  private token: number = -1
  private active: boolean = false

  aboutToAppear(): void {
    this.active = true; this.token = this.selection.popupToken()
    this.sources = this.selection.tasks()
    this.load()
  }
  aboutToDisappear(): void { this.active = false; this.open = false }
  valid(): boolean { return this.active && this.selection.popupAvailable(TaskOperation.Move, this.token) }
  dismiss(): void { if (this.token === this.selection.popupToken() && !this.selection.busy) this.selection.cancelPopup() }

  async load(): Promise<void> {
    if (!this.valid() || this.loading) return
    this.loading = true; this.message = ''
    try {
      const snapshot = await this.selection.moveTargets()
      if (this.valid()) {
        this.repositoryNames = snapshot.repositoryNames
        this.sections = refileSections(snapshot.targets)
      }
    } catch (error) { if (this.valid()) this.message = coreErrorMessage(error as CoreBridgeError) }
    finally { if (this.active) this.loading = false }
  }

  @Builder
  sourcePreview() {
    TaskMovePreview({ tasks: this.sources, expandPanel: (): void => { this.detent = '90%' } })
  }

  @Builder
  panel() {
    MoveToTarget({ sections: this.sections, repositoryNames: this.repositoryNames, selectionKey: `${this.token}`,
      loading: this.loading, busy: this.selection.busy, message: this.message || this.selection.message,
      close: (): void => { this.dismiss() },
      sourcePreview: (): void => { this.sourcePreview() },
      choose: (target: CoreRefileTarget): void => {
        if (this.valid()) this.selection.execute(this.getUIContext(), TaskOperation.Move, target)
      },
      retry: (): void => {
        if (this.selection.message) this.selection.reset()
        else this.load()
      } })
  }

  build() {
    Column().width(0).height(0).bindSheet($$this.open, this.panel, {
      height: '75%', detents: ['75%', '90%'], detentSelection: this.detent,
      preferType: SheetType.BOTTOM, dragBar: true, showClose: false, backgroundColor: '#363A38',
      keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_RESIZE,
      onWillDismiss: (action): void => {
        if (!this.selection.busy) { action.dismiss(); this.dismiss() }
      }
    })
  }
}
