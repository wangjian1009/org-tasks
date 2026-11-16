import { TaskActionItem, TaskOperation, taskSwipeMenuWidth } from '../ui/TaskActionPresentation'
import { TaskActionMenu } from './TaskActionMenu'

@Component
export struct TaskSwipeActions {
  @Prop items: TaskActionItem[] = []
  @Prop busy: boolean = false
  @Prop enableConvertToProject: boolean = false
  @Prop idPrefix: string = 'task_swipe'
  convertToProject: () => void = () => {}

  menuItems(): TaskActionItem[] {
    if (!this.enableConvertToProject) return this.items
    const project: TaskActionItem = { id: TaskOperation.Project, title: '项目', label: '转换为项目',
      icon: $r('app.media.ui_folder'), action: this.convertToProject }
    const items = [...this.items]
    const selection = items.findIndex(item => item.id === TaskOperation.Select)
    items.splice(selection < 0 ? items.length : selection, 0, project)
    return items
  }

  build() {
    Row() {
      TaskActionMenu({ items: this.menuItems(), busy: this.busy, idPrefix: this.idPrefix })
        .width(Math.max(0, taskSwipeMenuWidth(this.menuItems()) - 16))
    }.width(taskSwipeMenuWidth(this.menuItems())).height('100%').padding({ left: 4, right: 12 }).alignItems(VerticalAlign.Center)
  }
}
