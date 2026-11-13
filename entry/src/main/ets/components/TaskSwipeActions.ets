import { TaskActionItem, taskSwipeMenuWidth } from '../ui/TaskActionPresentation'
import { TaskActionMenu } from './TaskActionMenu'

@Component
export struct TaskSwipeActions {
  @Prop items: TaskActionItem[] = []
  @Prop busy: boolean = false
  @Prop idPrefix: string = 'task_swipe'

  build() {
    Row() {
      TaskActionMenu({ items: this.items, busy: this.busy, idPrefix: this.idPrefix })
        .width(Math.max(0, taskSwipeMenuWidth(this.items) - 16))
    }.width(taskSwipeMenuWidth(this.items)).height('100%').padding({ left: 4, right: 12 }).alignItems(VerticalAlign.Center)
  }
}
