import { DataSet } from '../services/DataSet'
import { TaskEditorController } from '../ui/TaskEditorController'
import { InternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { TaskRightSwipeAction } from '../ui/TaskActionPresentation'
import { RegionAreaPolicy, TaskDateDisplay, TaskTimeDisplay } from '../ui/TaskListPresentation'
import { TaskEditor } from './editors/TaskEditor'
import { RightSwipe } from './RightSwipe'

// 列表在编辑卡片外接入右滑，不向卡片传递手势或页面策略。
@Component
export struct TaskSwipeEditor {
  dataSet: DataSet | undefined = undefined
  taskId: string = ''
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop documentMode: boolean = false
  @Prop contentHidden: boolean = false
  @Prop hiddenTags: string[] = []
  @Prop instanceKey: string = ''
  @Prop readOnly: boolean = false
  @Prop rightSwipeAction: TaskRightSwipeAction = 'schedule'
  @Prop expandOnRowClick: boolean = false
  @Prop dateDisplay: TaskDateDisplay = TaskDateDisplay.None
  @Prop timeDisplay: TaskTimeDisplay = TaskTimeDisplay.None
  @Prop regionAreaPolicy: RegionAreaPolicy | undefined = undefined
  @Prop referenceTime: number = Date.now()
  scrollHost: Scroller | undefined = undefined
  scrollHostId: string = ''
  private controller: TaskEditorController = new TaskEditorController()

  activate(): void {
    if (this.readOnly) return
    if (this.rightSwipeAction === 'schedule') this.controller.openSchedule()
    else if (this.rightSwipeAction === 'move') this.controller.openMove()
  }

  build() {
    RightSwipe({ disabled: this.readOnly || this.rightSwipeAction === 'none',
      canActivate: (): boolean => this.controller.canActivate(), action: (): void => { this.activate() } }) {
      TaskEditor({ dataSet: this.dataSet, taskId: this.taskId, controller: this.controller,
        internalLinkProcessor: this.internalLinkProcessor, documentMode: this.documentMode,
        contentHidden: this.contentHidden, hiddenTags: this.hiddenTags, instanceKey: this.instanceKey,
        readOnly: this.readOnly, expandOnRowClick: this.expandOnRowClick,
        dateDisplay: this.dateDisplay, timeDisplay: this.timeDisplay, regionAreaPolicy: this.regionAreaPolicy,
        referenceTime: this.referenceTime, scrollHost: this.scrollHost, scrollHostId: this.scrollHostId })
    }
  }
}
