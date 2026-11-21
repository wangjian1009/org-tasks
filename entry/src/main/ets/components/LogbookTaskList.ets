import { DataSet } from '../services/DataSet'
import { CoreNotificationsView } from './CoreNotificationsView'
import { NotificationManager } from '../services/NotificationManager'
import { LogbookTaskItem, LogbookTaskGroup, LogbookGroup } from '../ui/LogbookPresentation'
import { TaskEditor } from './editors/TaskEditor'
import { LogShowPolicy } from '../ui/TaskLogPresentation'
import { TaskRegion } from './TaskRegion'
import { RegionAreaPolicy, TaskDateDisplay, TaskTimeDisplay } from '../ui/TaskListPresentation'
import { TaskSelectionRow } from './TaskSelectionRow'
import { TaskSelectionToolbar } from './TaskSelectionToolbar'
import { TaskSelectionController } from '../ui/TaskSelectionController'
import { TaskSwipeItem } from './TaskSwipeItem'
import { TaskEditorController } from '../ui/TaskEditorController'
import { TaskOperation, TaskSingleOperation, TaskBatchAction } from '../ui/TaskActionPresentation'
import { CoreTask } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'

@Component
export struct LogbookTaskList {
  dataSet: DataSet | undefined = undefined
  private taskDataSet(): DataSet {
    if (!this.dataSet) throw new Error('未提供页面数据管理对象')
    return this.dataSet
  }

  private listScroller: ListScroller = new ListScroller()
  @State showNotifications: boolean = false
  private stopNotifications: (() => void) | undefined = undefined
  @Prop ready: boolean = false
  @Prop trashMode: boolean = false
  @Prop singleOperations: TaskSingleOperation[] = [TaskOperation.Delete]
  @Prop bulkOperations: TaskBatchAction[] = [TaskOperation.Delete]
  @Prop groups: LogbookGroup[] = []
  @Prop referenceTime: number = Date.now()
  @State selection: TaskSelectionController = new TaskSelectionController()

  aboutToAppear(): void {
    this.stopNotifications = NotificationManager.watchVisibility(visible => { this.showNotifications = visible })
    this.selection.connect(this.taskDataSet(), (): CoreTask[] => this.allItems().map(item => item.task),
      () => this.bulkOperations, (): boolean => this.ready, this.listScroller)
  }

  aboutToDisappear(): void {
    this.stopNotifications?.()
    this.stopNotifications = undefined
    this.selection.close()
  }

  allItems(): LogbookTaskItem[] {
    const result: LogbookTaskItem[] = []
    for (const group of this.groups) result.push(...group.items)
    return result
  }

  @Builder
  groupHeader(group: LogbookGroup) {
    if (group.kind === 'day') {
      Row({ space: 8 }) {
        Text(group.title).fontSize(25).fontWeight(FontWeight.Bold).fontColor(UiColor.text).flexShrink(0)
        Text(group.subtitle).fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiColor.secondary).flexShrink(0)
        Divider().layoutWeight(1).color(UiColor.outline).strokeWidth(0.5)
      }.width('100%').height(48).alignItems(VerticalAlign.Center)
    } else {
      Column({ space: 7 }) {
        Divider().color(UiColor.outline).strokeWidth(0.5)
        Text(group.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiColor.text).width('100%')
      }.width('100%').padding({ top: 9, bottom: 6 })
    }
  }

  @Builder
  itemRow(item: LogbookTaskItem, group: LogbookGroup) {
    TaskSwipeItem({ dataSet: this.taskDataSet(), taskId: this.taskDataSet().taskKey(item.task.id),
      readOnly: !this.ready, singleOperations: this.singleOperations, itemId: `logbook_item_${item.key}`, busy: this.selection.selecting || this.selection.blocked(),
      selection: this.selection, menuIdPrefix: 'logbook_swipe', content: (controller: TaskEditorController): void => { this.taskContent(item, group, controller) } })
  }

  @Builder
  taskContent(item: LogbookTaskItem, group: LogbookGroup, controller: TaskEditorController) {
    TaskSelectionRow({ selecting: this.selection.selecting,
      busy: this.selection.blocked(), selectedIndex: this.selection.selectedKeys.indexOf(this.taskDataSet().taskKey(item.task.id)),
      heading: item.task.heading, horizontalInset: 0,
      begin: (): void => { this.selection.start(item.task.id) }, toggle: (): void => { this.selection.toggle(item.task.id) } }) {
        Column() {
        TaskEditor({ controller, allowDeletion: this.ready && !this.trashMode, dataSet: this.taskDataSet(), taskId: this.taskDataSet().taskKey(item.task.id), readOnly: true, logShowPolicy: LogShowPolicy.LogShowAlways, allowCompletion: this.ready && !this.trashMode, instanceKey: item.key,
          todayFlag: this.trashMode, dateDisplay: group.kind === 'day' ? TaskDateDisplay.None : this.trashMode ? TaskDateDisplay.Deleted : TaskDateDisplay.Closed,
          timeDisplay: this.trashMode && group.kind === 'day' ? TaskTimeDisplay.Deleted : TaskTimeDisplay.None,
          regionAreaPolicy: this.trashMode || group.kind === 'day' ? RegionAreaPolicy.None : RegionAreaPolicy.CategoryProject,
          referenceTime: this.referenceTime, scrollHost: this.listScroller, scrollHostId: 'logbook_task_list' })
        if (this.trashMode) {
          Text([item.task.property('SOURCE_CATEGORY'), item.task.property('SOURCE_PROJECT_NAME')].filter((value: string | null): boolean => value !== null && value.length > 0).join(' · ') || '来源未记录')
            .fontSize(12).fontColor(UiColor.secondary).width('100%').padding({ left: 26, bottom: 8 }).maxLines(2)
        }
        }.width('100%')
      }
  }

  currentGroup(group: LogbookGroup): LogbookGroup { return this.groups.find(item => item.key === group.key) ?? group }

  currentItems(group: LogbookGroup, regionKey: string = ''): LogbookTaskItem[] {
    const current = this.currentGroup(group)
    return regionKey ? current.groups.find(region => region.key === regionKey)?.items ?? [] : current.items
  }

  @Builder
  groupItems(group: LogbookGroup) {
    if (group.kind === 'day' && !this.trashMode) {
      ForEach(this.currentGroup(group).groups, (region: LogbookTaskGroup) => {
        TaskRegion({ category: region.category || '未分类', project: region.kind === 'project' ? region : null }) {
          ForEach(this.currentItems(group, region.key), (item: LogbookTaskItem) => {
            this.itemRow(item, group)
          }, (item: LogbookTaskItem) => item.key)
        }
      }, (region: LogbookTaskGroup) => region.key)
    } else {
      ForEach(this.currentItems(group), (item: LogbookTaskItem) => {
        this.itemRow(item, group)
      }, (item: LogbookTaskItem) => item.key)
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      List({ scroller: this.listScroller }) {
        if (this.showNotifications) {
          ListItem() { CoreNotificationsView({ horizontalInset: 0 }) }
        }
        ForEach(this.groups, (group: LogbookGroup) => {
          ListItem() { this.groupHeader(this.currentGroup(group)) }
          this.groupItems(this.currentGroup(group))
        }, (group: LogbookGroup) => group.key)
      }.id('logbook_task_list').width('100%').height('100%').padding({ left: 20, right: 20, bottom: this.selection.selecting ? 196 : 16 })
        .scrollBar(BarState.Off)
        .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .edgeEffect(EdgeEffect.None)
      TaskSelectionToolbar({ selection: this.selection, operations: this.bulkOperations, idPrefix: 'logbook' })
    }.width('100%').height('100%')
  }
}
