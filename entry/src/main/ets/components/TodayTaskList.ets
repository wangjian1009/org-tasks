import { FrameCallback } from '@ohos.arkui.UIContext'
import { DataSet } from '../services/DataSet'
import { PageListPosition } from '../services/PageListPosition'
import { TaskInlineSession } from '../services/TaskInlineService'
import { CoreNotificationsView } from './CoreNotificationsView'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/NotificationManager'
import { taskRenderKey } from '../ui/TaskPresentation'
import { TodaySection, TodayTaskItem, TodayTaskGroup, TodayTimedTaskItem, todayPreviewGroups, todayRegionKey } from '../ui/TodayPresentation'
import { UiColor } from '../ui/Theme'
import { RegionAreaPolicy } from '../ui/TaskListPresentation'
import { TaskRegion } from './TaskRegion'
import { CategoryRegion } from './CategoryRegion'
import { ScheduleRegion } from './ScheduleRegion'
import { taskRegion, TaskRegionData } from '../ui/TaskRegionPresentation'
import { TaskSwipeItem } from './TaskSwipeItem'
import { TaskSingleOperation } from '../ui/TaskActionPresentation'

interface NotificationListAnchor { key: string; y: number }
class NotificationLayoutFrame extends FrameCallback {
  private callback: () => void
  constructor(callback: () => void) { super(); this.callback = callback }
  onFrame(_time: number): void {}
  onIdle(_remaining: number): void { this.callback() }
}

@Component
export struct TodayTaskList {
  dataSet: DataSet | undefined = undefined
  @Prop positionKey: string = ''
  private initialIndex: number = 0
  private firstIndex: number = 0
  private pendingOffset: number | undefined = undefined
  private pendingAnchor: number | undefined = undefined
  @Prop readOnly: boolean = false
  @Prop singleOperations: TaskSingleOperation[] = []
  @StorageLink('taskChecklistDragging') checklistDragging: boolean = false
  private listScroller: ListScroller = new ListScroller()
  @StorageLink('coreNotifications') @Watch('notificationsChanged') notificationState: CoreNotificationsState = emptyCoreNotificationsState()
  @State showNotifications: boolean = false
  private active: boolean = false
  private notificationLayout: number = 0
  @Prop sections: TodaySection[] = []
  @Prop timedItems: TodayTimedTaskItem[] = []
  @Prop regionKeys: string[] = []
  @Prop referenceTime: number = Date.now()
  @Prop expandOnRowClick: boolean = false
  @Prop regionPreviewLimit: number = 0
  @State expandedRegionKeys: string[] = []

  aboutToAppear(): void {
    this.active = true
    this.showNotifications = this.notificationState.notifications.length > 0
    const position = PageListPosition.read(this.positionKey)
    const found = position.key ? this.positionKeys().indexOf(position.key) : -1
    // 重进预览页时，之前展开区中的记录可能已隐藏，不恢复失效的索引和像素锚点。
    if (this.regionPreviewLimit > 0 && position.key && found < 0) {
      this.initialIndex = 0; this.firstIndex = 0; this.pendingOffset = 0; this.pendingAnchor = undefined
      return
    }
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
    for (const regionKey of this.displayRegionKeys()) {
      if (regionKey === 'schedule') { keys.push('schedule-heading', 'schedule-items'); continue }
      const section = this.sections.find(item => item.key === regionKey)!
      keys.push(section.key)
      for (const group of this.sectionGroups(section.key)) {
        keys.push(group.project === null ? JSON.stringify([group.items[0].task.repoId, group.items[0].task.id]) : group.key)
        if (this.ordinaryMoreAfter(section.key, group.key)) keys.push(todayRegionKey(section.key))
      }
    }
    return keys
  }

  private displayRegionKeys(): string[] {
    if (this.regionKeys.length > 0) return this.regionKeys
    const keys = this.sections.map(section => section.key)
    if (this.timedItems.length > 0) keys.unshift('schedule')
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

  private taskDataSet(): DataSet {
    if (!this.dataSet) throw new Error('未提供页面数据管理对象')
    return this.dataSet
  }

  @Builder
  taskItem(item: TodayTaskItem) {
    TaskSwipeItem({ dataSet: this.taskDataSet(), taskId: this.taskDataSet().taskKey(item.task.id), readOnly: this.readOnly,
      singleOperations: this.singleOperations, rightSwipeAction: 'schedule', referenceTime: this.referenceTime,
      expandOnRowClick: this.expandOnRowClick, scrollHost: this.listScroller, scrollHostId: 'today_task_list' })
  }

  @Builder
  timedTaskItem(item: TodayTimedTaskItem) {
    TaskSwipeItem({ dataSet: this.taskDataSet(), taskId: this.taskDataSet().taskKey(item.task.id), readOnly: this.readOnly,
      singleOperations: this.singleOperations, rightSwipeAction: 'schedule', timeDisplay: item.timeDisplay, regionAreaPolicy: RegionAreaPolicy.None,
      referenceTime: this.referenceTime, expandOnRowClick: this.expandOnRowClick, scrollHost: this.listScroller, scrollHostId: 'today_task_list' })
  }

  private sectionGroups(sectionKey: string): TodayTaskGroup[] {
    const section = this.sections.find(section => section.key === sectionKey)
    return section ? todayPreviewGroups(section, this.regionPreviewLimit, this.expandedRegionKeys) : []
  }

  private ordinaryMoreAfter(sectionKey: string, groupKey: string): boolean {
    if (this.regionPreviewLimit <= 0 || this.expandedRegionKeys.includes(todayRegionKey(sectionKey))) return false
    const ordinary = this.sections.find(section => section.key === sectionKey)?.groups.filter(group => group.project === null) ?? []
    return ordinary.length > this.regionPreviewLimit && ordinary[this.regionPreviewLimit - 1].key === groupKey
  }

  private projectHasMore(sectionKey: string, groupKey: string): boolean {
    if (this.regionPreviewLimit <= 0 || this.expandedRegionKeys.includes(todayRegionKey(sectionKey, groupKey))) return false
    return (this.sections.find(section => section.key === sectionKey)?.groups.find(group => group.key === groupKey)?.items.length ?? 0) > this.regionPreviewLimit
  }

  private async expandRegion(sectionKey: string, groupKey: string): Promise<void> {
    if (!await TaskInlineSession.end(true)) return
    const key = todayRegionKey(sectionKey, groupKey)
    if (this.active && !this.expandedRegionKeys.includes(key)) this.expandedRegionKeys = this.expandedRegionKeys.concat(key)
  }

  private remainingCount(sectionKey: string, groupKey: string): number {
    const groups = this.sections.find(section => section.key === sectionKey)?.groups ?? []
    const total = groupKey ? (groups.find(group => group.key === groupKey)?.items.length ?? 0) :
      groups.filter(group => group.project === null).length
    return Math.max(0, total - this.regionPreviewLimit)
  }

  @Builder
  loadMore(sectionKey: string, groupKey: string) {
    ListItem() {
      Button({ type: ButtonType.Normal }) {
        Text(`还显示 ${this.remainingCount(sectionKey, groupKey)} 个`)
          .fontSize(12).fontColor(UiColor.secondary).width('100%').textAlign(TextAlign.Start)
      }
        .id(`region_more:${todayRegionKey(sectionKey, groupKey)}`)
        .backgroundColor(Color.Transparent).borderRadius(0)
        .width('100%').height(40).padding({ left: 8, right: 8 })
        .accessibilityText(`加载${this.sections.find(section => section.key === sectionKey)?.category || '未分类'}${groupKey ? '项目' : ''}区域剩余的 ${this.remainingCount(sectionKey, groupKey)} 个任务`)
        .onClick((): void => { this.expandRegion(sectionKey, groupKey) })
    }
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
        this.taskItem(item)
      }, (item: TodayTaskItem) => this.taskDataSet().taskKey(item.task.id))
      if (this.projectHasMore(sectionKey, groupKey)) {
        this.loadMore(sectionKey, groupKey)
      }
    }
  }

  @Builder
  categoryBlock(section: TodaySection) {
    ListItem() { CategoryRegion({ category: section.category || '未分类' }) }
    ForEach(this.sectionGroups(section.key), (group: TodayTaskGroup) => {
      if (group.project !== null) {
        this.projectBlock(section.key, group.key)
      } else {
        this.taskItem(group.items[0])
        if (this.ordinaryMoreAfter(section.key, group.key)) {
          this.loadMore(section.key, '')
        }
      }
    }, (group: TodayTaskGroup) => group.project === null ? this.taskDataSet().taskKey(group.items[0].task.id) : group.key)
  }

  build() {
    List({ scroller: this.listScroller, initialIndex: this.initialIndex }) {
      // 保留零高度列表项，通知变化不改变后续编辑器的列表槽位。
      ListItem() { CoreNotificationsView({ horizontalInset: 0 }) }
        .height(this.showNotifications ? 'auto' : 0)
      ForEach(this.displayRegionKeys(), (key: string) => {
        if (key === 'schedule') {
          ListItem() { ScheduleRegion() }
          ListItemGroup() {
            ForEach(this.timedItems, (item: TodayTimedTaskItem) => {
              this.timedTaskItem(item)
            }, (item: TodayTimedTaskItem) => JSON.stringify([this.taskDataSet().taskKey(item.task.id), item.timeDisplay]))
          }.width('100%')
        } else {
          ForEach(this.sections.filter(section => section.key === key), (section: TodaySection) => {
            this.categoryBlock(section)
          }, (section: TodaySection) => section.key)
        }
      }, (key: string) => key)
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
