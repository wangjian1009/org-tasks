import { FrameCallback } from '@ohos.arkui.UIContext'
import { TaskEditorDataManager } from '../services/TaskEditorDataManager'
import { PageListPosition } from '../services/PageListPosition'
import { DataSetManager } from '../services/DataSetManager'
import { CoreNotificationsView } from './CoreNotificationsView'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/NotificationManager'
import { taskRenderKey } from '../ui/TaskPresentation'
import { TodaySection, TodayTaskItem, TodayTaskGroup, TodayTimedTaskItem } from '../ui/TodayPresentation'
import { RegionAreaPolicy } from '../ui/TaskListPresentation'
import { TaskRegion } from './TaskRegion'
import { CategoryRegion } from './CategoryRegion'
import { ScheduleRegion } from './ScheduleRegion'
import { taskRegion, TaskRegionData } from '../ui/TaskRegionPresentation'
import { TaskEditor } from './editors/TaskEditor'
import { TaskRightSwipeAction } from '../ui/TaskActionPresentation'

interface NotificationListAnchor { key: string; y: number }
class NotificationLayoutFrame extends FrameCallback {
  private callback: () => void
  constructor(callback: () => void) { super(); this.callback = callback }
  onFrame(_time: number): void {}
  onIdle(_remaining: number): void { this.callback() }
}

@Component
export struct TodayTaskList {
  dataSetManager: DataSetManager | undefined = undefined
  dataSetName: string = 'tasks'
  @Prop positionKey: string = ''
  private editorManager: TaskEditorDataManager | undefined = undefined
  private initialIndex: number = 0
  private firstIndex: number = 0
  private pendingOffset: number | undefined = undefined
  private pendingAnchor: number | undefined = undefined
  @Prop readOnly: boolean = false
  @StorageLink('taskChecklistDragging') checklistDragging: boolean = false
  private listScroller: ListScroller = new ListScroller()
  @StorageLink('coreNotifications') @Watch('notificationsChanged') notificationState: CoreNotificationsState = emptyCoreNotificationsState()
  @State showNotifications: boolean = false
  private active: boolean = false
  private notificationLayout: number = 0
  @Prop sections: TodaySection[] = []
  @Prop timedItems: TodayTimedTaskItem[] = []
  @Prop referenceTime: number = Date.now()
  @Prop rightSwipeAction: TaskRightSwipeAction = 'schedule'
  @Prop expandOnRowClick: boolean = false

  aboutToAppear(): void {
    this.active = true
    this.showNotifications = this.notificationState.notifications.length > 0
    const position = PageListPosition.read(this.positionKey)
    const found = position.key ? this.positionKeys().indexOf(position.key) : -1
    this.initialIndex = found >= 0 ? found : position.index; this.firstIndex = this.initialIndex
    this.pendingOffset = position.offset; this.pendingAnchor = position.anchor
  }

  aboutToDisappear(): void { this.active = false; this.notificationLayout++ }

  notificationsChanged(): void {
    const next = this.notificationState.notifications.length > 0
    let anchor: NotificationListAnchor | undefined = undefined
    if (this.active && this.pendingOffset === undefined) {
      try {
        if (this.listScroller.currentOffset().yOffset > 0.5) {
          const visible = this.listScroller.getVisibleListContentInfo(24, 1)
          const key = this.positionKeys()[visible.index]
          if (key && key !== 'notifications') anchor = { key, y: this.listScroller.getItemRect(visible.index).y }
        }
      } catch (_) { /* 首次布局尚未绑定控制器时直接呈现通知。 */ }
    }
    this.showNotifications = next
    const generation = ++this.notificationLayout
    if (!anchor) return
    const saved = anchor
    this.getUIContext().postFrameCallback(new NotificationLayoutFrame((): void => {
      if (!this.active || generation !== this.notificationLayout) return
      const index = this.positionKeys().indexOf(saved.key)
      if (index < 0) return
      try {
        const shift = this.listScroller.getItemRect(index).y - saved.y
        if (Math.abs(shift) > 0.5) this.listScroller.scrollBy(0, shift)
      } catch (_) { /* 变化已使该记录离开可见区时由列表正常处理。 */ }
    }))
  }

  private positionKeys(): string[] {
    const keys: string[] = ['notifications']
    if (this.timedItems.length > 0) keys.push('schedule-heading', 'schedule-items')
    for (const section of this.sections) {
      keys.push(section.key)
      for (const group of section.groups) keys.push(group.project === null ? JSON.stringify([group.items[0].task.repoId, group.items[0].task.id]) : group.key)
    }
    return keys
  }

  private savePosition(): void {
    if (this.pendingOffset !== undefined) return
    const offset = this.listScroller.currentOffset().yOffset
    try {
      const visible = this.listScroller.getVisibleListContentInfo(24, 1)
      const index = visible.index >= 0 ? visible.index : this.firstIndex
      PageListPosition.save(this.positionKey, index, offset, this.listScroller.getItemRect(index).y, this.positionKeys()[index])
    } catch (_) { PageListPosition.save(this.positionKey, this.firstIndex, offset) }
  }

  private editorDataManager(): TaskEditorDataManager {
    if (!this.editorManager) this.editorManager = this.dataSetManager ? TaskEditorDataManager.managed(this.dataSetManager, this.dataSetName) :
      new TaskEditorDataManager(this.getUIContext().getHostContext()!)
    return this.editorManager
  }

  @Builder
  taskItem(item: TodayTaskItem) {
    TaskEditor({ dataManager: this.editorDataManager(), dataSet: this.editorDataManager().dataSet(item.task), readOnly: this.readOnly, referenceTime: this.referenceTime, rightSwipeAction: this.rightSwipeAction,
      expandOnRowClick: this.expandOnRowClick, scrollHost: this.listScroller, scrollHostId: 'today_task_list' })
  }

  private sectionGroups(sectionKey: string): TodayTaskGroup[] {
    return this.sections.find(section => section.key === sectionKey)?.groups ?? []
  }

  private projectItems(sectionKey: string, groupKey: string): TodayTaskItem[] {
    return this.sectionGroups(sectionKey).find(group => group.key === groupKey)?.items ?? []
  }

  private projectArea(sectionKey: string, groupKey: string): TaskRegionData | null {
    const task = this.projectItems(sectionKey, groupKey)[0]?.task
    return task ? taskRegion(task) : null
  }

  @Builder
  projectBlock(sectionKey: string, groupKey: string) {
    TaskRegion({ project: this.projectArea(sectionKey, groupKey) }) {
      ForEach(this.projectItems(sectionKey, groupKey), (item: TodayTaskItem) => {
        ListItem() { this.taskItem(item) }
      }, (item: TodayTaskItem) => this.dataSetManager?.itemKey(this.dataSetName, item.task.id) ?? taskRenderKey(item.task))
    }
  }

  build() {
    List({ scroller: this.listScroller, initialIndex: this.initialIndex }) {
      // 保留零高度列表项，通知变化不改变后续编辑器的列表槽位。
      ListItem() { CoreNotificationsView({ horizontalInset: 0 }) }
        .height(this.showNotifications ? 'auto' : 0)
      if (this.timedItems.length > 0) {
        ListItem() { ScheduleRegion() }
        ListItemGroup() {
          ForEach(this.timedItems, (item: TodayTimedTaskItem) => {
            ListItem() {
              TaskEditor({ dataManager: this.editorDataManager(), dataSet: this.editorDataManager().dataSet(item.task), readOnly: this.readOnly, timeDisplay: item.timeDisplay, regionAreaPolicy: RegionAreaPolicy.None,
                referenceTime: this.referenceTime, rightSwipeAction: this.rightSwipeAction,
                expandOnRowClick: this.expandOnRowClick, scrollHost: this.listScroller, scrollHostId: 'today_task_list' })
            }
          }, (item: TodayTimedTaskItem) => JSON.stringify([this.dataSetManager?.itemKey(this.dataSetName, item.task.id) ?? taskRenderKey(item.task), item.timeDisplay]))
        }.width('100%')
      }
      ForEach(this.sections, (section: TodaySection) => {
        ListItem() { CategoryRegion({ category: section.category || '未分类' }) }
        ForEach(this.sectionGroups(section.key), (group: TodayTaskGroup) => {
          if (group.project !== null) {
            this.projectBlock(section.key, group.key)
          } else {
            ListItem() { this.taskItem(group.items[0]) }
          }
        }, (group: TodayTaskGroup) => group.project === null && this.dataSetManager ? this.dataSetManager.itemKey(this.dataSetName, group.items[0].task.id) : group.key)
      }, (section: TodaySection) => section.key)
    }.id('today_task_list').width('100%').layoutWeight(1).padding({ left: 12, right: 12, bottom: 16 })
      .onScrollIndex((start: number): void => { this.firstIndex = start })
      .onDidScroll((_offset: number, state: ScrollState): void => { if (state !== ScrollState.Idle) this.savePosition() })
      .onAreaChange((_old: Area, area: Area): void => {
        if (Number(area.height) > 0 && this.pendingOffset !== undefined) {
          const offset = this.pendingOffset; this.pendingOffset = undefined
          if (this.pendingAnchor !== undefined) {
            this.listScroller.scrollBy(0, this.listScroller.getItemRect(this.initialIndex).y - this.pendingAnchor)
          } else this.listScroller.scrollTo({ xOffset: 0, yOffset: offset, animation: false })
        }
      })
      .enableScrollInteraction(!this.checklistDragging)
      .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .edgeEffect(EdgeEffect.None)
  }
}
