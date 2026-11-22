import { AppDataManager } from '../services/AppDataManager'
import { PageNavigator } from '../services/PageNavigator'
import { CaptureService } from '../services/CaptureService'
import { DataSetManager, DataSet } from '../services/DataSetManager'
import { TaskInlineSession } from '../services/TaskInlineService'
import { NotificationEmptyState } from '../components/NotificationEmptyState'
import { CoreNotificationsView } from '../components/CoreNotificationsView'
import { NotificationManager } from '../services/NotificationManager'
import { taskRenderKey } from '../ui/TaskPresentation'
import { UiColor } from '../ui/Theme'
import { KeyboardAvoidMode } from '@kit.ArkUI'
import { FrameCallback } from '@ohos.arkui.UIContext'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/controls/EmptyState'
import { TaskEditor } from '../components/editors/TaskEditor'
import { TaskSwipeItem } from '../components/TaskSwipeItem'
import { TaskEditorController } from '../ui/TaskEditorController'
import { TaskRegion } from '../components/TaskRegion'
import { RegionAreaPolicy } from '../ui/TaskListPresentation'
import { TaskSelectionRow } from '../components/TaskSelectionRow'
import { TaskSelectionToolbar } from '../components/TaskSelectionToolbar'
import { TaskSelectionController } from '../ui/TaskSelectionController'
import { TaskPageActionPolicy, taskActionPolicy, taskPageActionPolicy, TaskOperation } from '../ui/TaskActionPresentation'
import { OrgContentView } from '../components/OrgContentView'
import { RecentDay, RecentTaskGroup, recentDays, unplannedSpacer } from '../ui/InboxPresentation'
import { CoreBridgeError, CoreTask, CoreTaskPath, coreErrorMessage } from '../services/NativeCoreService'

class InboxLayoutFrame extends FrameCallback {
  private callback: () => void
  constructor(callback: () => void) { super(); this.callback = callback }
  onFrame(_time: number): void {}
  onIdle(_remaining: number): void { this.callback() }
}

@Entry
@Component
struct Inbox {
  private dataManager: DataSetManager | undefined = undefined
  private tasksDataSet: DataSet | undefined = undefined
  private recentDataSet: DataSet | undefined = undefined
  private targetDataSet: DataSet | undefined = undefined
  private stops: (() => void)[] = []
  @State pageReady: boolean = false
  @StorageLink('taskInlineActive') @Watch('pageInlineChanged') pageInlineActive: string = ''
  private taskDataSet(name: string = 'tasks'): DataSet { return name === 'recent' ? this.recentDataSet! : this.tasksDataSet! }

  @State showNotifications: boolean = false
  private stopNotifications: (() => void) | undefined = undefined
  @State records: CoreTask[] = []
  @State recentGroups: RecentDay[] = []
  @State recentLayoutReady: boolean = false
  private recentLayoutPending: boolean = false
  @State recentMessage: string = ''
  @State rowTotalHeight: number = 0
  @State loading: boolean = true
  @State message: string = ''
  @State @Watch('drawerChanged') drawerOpen: boolean = false
  @State needsConfiguration: boolean = false
  @StorageLink('taskInlineActive') inlineActive: string = ''
  @StorageLink('taskInlineTyping') inlineTyping: boolean = false
  @StorageLink('taskChecklistDragging') checklistDragging: boolean = false
  @State captureOpen: boolean = false
  @State captureTitle: string = ''
  @State captureSaving: boolean = false
  @State captureMessage: string = ''
  @State actionBusy: boolean = false
  @State listHeight: number = 0
  @State selection: TaskSelectionController = new TaskSelectionController()
  private mergeFocusTimer: number = -1
  private visible: boolean = true
  private actionPolicy: TaskPageActionPolicy = taskActionPolicy({
    singleOperations: [TaskOperation.Move, TaskOperation.Cancel, TaskOperation.Someday, TaskOperation.Memo, TaskOperation.Project, TaskOperation.Delete],
    bulkOperations: [TaskOperation.Move, TaskOperation.Cancel, TaskOperation.Someday, TaskOperation.Memo, TaskOperation.Merge, TaskOperation.Delete]
  }, TaskOperation.Schedule)
  private recentActionPolicy: TaskPageActionPolicy = taskPageActionPolicy('recent')
  private listScroller: ListScroller = new ListScroller()
  private rowHeights: Map<string, number> = new Map()
  private requestId: number = 0
  private captureFocusTimer: number = -1
  private keyboardAvoidMode: KeyboardAvoidMode = KeyboardAvoidMode.OFFSET

  private stopExternalGuard: (() => void) | undefined = undefined
  aboutToAppear() {
    this.stopNotifications = NotificationManager.watchVisibility(visible => { this.showNotifications = visible })
    this.loadRecords()
  }

  onPageShow() {
    this.stopExternalGuard?.()
    this.stopExternalGuard = PageNavigator.shared.watchExternalLeaveGuard((): boolean =>
      !this.selection.busy && !this.selection.starting && !this.actionBusy && !this.captureSaving && (!this.captureOpen || !this.captureTitle))
    this.visible = true; this.loadRecords(); this.prepareRecentLayout()
  }
  onPageHide() {
    this.stopExternalGuard?.(); this.stopExternalGuard = undefined; this.visible = false
    clearTimeout(this.mergeFocusTimer)
    this.selection.close()
    if (!this.selection.busy) this.selection.reset()
  }
  aboutToDisappear() {
    this.stopNotifications?.()
    this.stopNotifications = undefined
    this.stopExternalGuard?.()
    this.selection.close()
    for (const stop of this.stops) stop()
    this.stops = []
    this.dataManager = undefined
    clearTimeout(this.captureFocusTimer)
    clearTimeout(this.mergeFocusTimer)
    this.visible = false
    if (this.captureOpen) this.getUIContext().setKeyboardAvoidMode(this.keyboardAvoidMode)
  }

  onBackPress(): boolean {
    if (this.selection.busy || this.selection.starting) return true
    if (this.selection.pendingAction) { this.selection.cancelPopup(); return true }
    if (this.selection.selecting) { this.selection.reset(); return true }
    if (TaskInlineSession.active()) { TaskInlineSession.end(!AppStorage.get<boolean>('taskInlineTyping')); return true }
    if (this.captureOpen) { this.closeCapture(); return true }
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    PageNavigator.shared.back(this.getUIContext())
    return true
  }

  drawerChanged() { if (this.drawerOpen && this.selection.selecting && !this.selection.busy) this.selection.reset() }

  connectSelection(): void {
    this.selection.connect(this.taskDataSet(), (): CoreTask[] => this.records, () => this.actionPolicy.bulkOperations,
      (): boolean => this.visible && this.pageReady && !this.drawerOpen && !this.captureOpen && !this.loading && !this.actionBusy && !this.checklistDragging,
      this.listScroller, (): void => { this.applyPageSnapshot() }, (path: CoreTaskPath): void => { this.revealMerged(path) })
  }

  revealMerged(path: CoreTaskPath): void {
    clearTimeout(this.mergeFocusTimer)
    this.mergeFocusTimer = setTimeout((): void => {
      if (!this.visible || this.selection.selecting) return
      const index = this.records.findIndex(item => JSON.stringify(item.fullPath) === JSON.stringify(path))
      if (index >= 0) {
        try { this.listScroller.scrollToIndex(index + (this.showNotifications ? 1 : 0), true, ScrollAlign.CENTER) }
        catch (_) { /* 尚未布局时保留结果高亮。 */ }
      }
    }, 100)
  }

  async capture() {
    if (!this.pageReady || this.needsConfiguration || this.captureOpen || this.drawerOpen || this.actionBusy || this.selection.selecting || this.selection.starting) return
    this.actionBusy = true
    try {
      if (!await TaskInlineSession.end(true) || !this.visible || this.drawerOpen) return
      this.keyboardAvoidMode = this.getUIContext().getKeyboardAvoidMode()
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE)
      this.captureMessage = ''
      this.captureOpen = true
    } catch (e) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: coreErrorMessage(e as CoreBridgeError), duration: 3000 })
      } catch (_) {
        // 页面退出时提示可能不可用。
      }
    } finally { this.actionBusy = false }
  }

  focusCapture() {
    clearTimeout(this.captureFocusTimer)
    this.captureFocusTimer = setTimeout((): void => {
      if (this.captureOpen && !this.captureSaving) {
        this.getUIContext().getFocusController().requestFocus('inbox_capture_title')
      }
    }, 150)
  }

  closeCapture() {
    if (this.captureSaving) return
    clearTimeout(this.captureFocusTimer)
    this.captureOpen = false
    this.getUIContext().setKeyboardAvoidMode(this.keyboardAvoidMode)
  }

  async saveCapture() {
    if (this.captureSaving || !this.pageReady) return
    const title = this.captureTitle.trim()
    if (!title) {
      this.captureMessage = '请输入标题'
      return
    }
    this.captureSaving = true
    this.captureMessage = ''
    try {
      const context = this.getUIContext().getHostContext()!
      await this.tasksDataSet!.operate((operationId: string): Promise<void> => CaptureService.save(context, title, operationId))
    } catch (e) {
      this.captureMessage = `保存失败：${coreErrorMessage(e as CoreBridgeError)}`
      return
    } finally {
      this.captureSaving = false
    }
    this.captureTitle = ''
    this.closeCapture()
  }

  measureRows() {
    let total = 0
    for (const record of this.records) total += this.rowHeights.get(record.id) || 0
    if (total !== this.rowTotalHeight) this.rowTotalHeight = total
  }

  @Builder
  plannedDivider() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Image($r('app.media.ui_recent_created')).width(22).height(22).accessibilityLevel('no')
        Text('最近新增').fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.primary)
      }.width('100%')
      Divider().color(UiColor.outline).strokeWidth(0.5)
    }.height(52).width('100%').padding({ left: 20, right: 20 }).justifyContent(FlexAlign.Center)
  }

  @Builder
  recentHeader(day: RecentDay) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(day.date).fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text).flexShrink(0)
        Text(day.weekday).fontSize(12).fontWeight(FontWeight.Medium).fontColor(UiColor.secondary).flexShrink(0)
      }.width('100%')
      Divider().color(UiColor.outline).strokeWidth(0.5)
    }.width('100%').height(48).padding({ left: 20, right: 20 }).justifyContent(FlexAlign.Center)
  }

  @Builder
  recordContent(record: CoreTask, controller: TaskEditorController) {
    Row() {
      TaskSelectionRow({ selecting: this.selection.selecting,
        busy: this.selection.blocked() || this.actionBusy,
        selectedIndex: this.selection.selectedKeys.indexOf(this.taskDataSet().taskKey(record.id)), heading: record.heading,
        highlighted: this.selection.mergedPath === JSON.stringify(record.fullPath),
        begin: (): void => { this.selection.start(record.id) }, toggle: (): void => { this.selection.toggle(record.id) } }) {
        TaskEditor({ controller, readOnly: !this.pageReady, dataSet: this.taskDataSet(), taskId: this.taskDataSet().taskKey(record.id), scrollHost: this.listScroller, scrollHostId: 'inbox_task_list' })
        if (this.selection.mergedPath === JSON.stringify(record.fullPath) && !this.inlineActive) {
          OrgContentView({ fragment: record.bodyHtml, empty: false, embedded: true, embeddedPadding: 8 })
            .width('100%').padding({ left: 27 })
        }
      }
    }.width('100%').padding({ left: 12, right: 12 })
      .onAreaChange((oldArea: Area, newArea: Area): void => {
        this.rowHeights.set(record.id, parseFloat(newArea.height.toString()))
        this.measureRows()
      })
  }

  @Builder
  recentRegion(group: RecentTaskGroup) {
    TaskRegion({ category: group.category || '未分类',
      project: group.kind === 'project' ? group : null }) {
      ForEach(group.items, (task: CoreTask) => {
        TaskSwipeItem({ singleOperations: taskPageActionPolicy('recent').singleOperations, dataSet: this.taskDataSet('recent'), taskId: this.taskDataSet('recent').taskKey(task.id),
          rightSwipeAction: this.recentActionPolicy.rightSwipeAction, regionAreaPolicy: RegionAreaPolicy.None,
          scrollHost: this.listScroller, scrollHostId: 'inbox_task_list',
          readOnly: !this.pageReady, busy: this.selection.selecting || this.selection.starting || this.selection.busy || this.actionBusy })
      }, (task: CoreTask) => taskRenderKey(task))
    }
  }

  // 分组由 List 的内边距定位；通栏条目扩展回页面宽度，避免包装原生列表分组。
  @Styles
  fullWidthItem() {
    .width('calc(100% + 24vp)').margin({ left: -12, right: -12 })
  }

  async loadRecords(reload: boolean = false) {
    if (!this.dataManager) {
      this.dataManager = AppDataManager.shared(this.getUIContext().getHostContext()!).manager
      this.tasksDataSet = this.dataManager.dataSet('inboxTasks')
      this.recentDataSet = this.dataManager.dataSet('inboxRecent')
      this.targetDataSet = this.dataManager.dataSet('inboxFile')
      this.stops.push(this.tasksDataSet.subscribe((): void => { this.applyPageSnapshot() }))
      this.stops.push(this.recentDataSet.subscribe((): void => { this.applyPageSnapshot() }))
      this.stops.push(this.targetDataSet.subscribe((): void => { this.applyPageSnapshot() }))
    }
    this.connectSelection()
    if (this.tasksDataSet?.data) this.applyPageSnapshot()
    try {
      await this.dataManager.start()
      this.applyPageSnapshot()
      if (reload) await (this.recentDataSet?.error ? this.recentDataSet : this.targetDataSet?.error ? this.targetDataSet : this.tasksDataSet)!.refresh()
    } catch (error) { this.loading = false; this.message = (error as Error).message }
  }

  pageInlineChanged(): void { if (!this.pageInlineActive) this.applyPageSnapshot() }

  applyPageSnapshot(): void {
    const dataSet = this.tasksDataSet
    if (!dataSet || TaskInlineSession.active() || this.selection.selecting || this.selection.busy) return
    const data = dataSet.data
    const target = this.targetDataSet?.data, recent = this.recentDataSet?.data
    this.message = dataSet.error || this.targetDataSet?.error || ''
    this.recentMessage = this.recentDataSet?.error ?? ''
    // 同批结果独立通知；首屏等所需快照齐备，缓存也遵循相同发布边界。
    this.loading = (!data && !dataSet.error) || (!target && !this.targetDataSet?.error) || (!recent && !this.recentMessage)
    if (this.loading) { this.recentLayoutReady = false; return }
    this.pageReady = dataSet.isReady()
    this.needsConfiguration = !!target && (target.type !== 'file' || target.result.length === 0)
    this.records = data?.type === 'task' ? data.result.tasks : []
    this.recentGroups = recentDays(recent?.type === 'task' ? recent.result.tasks : [])
    this.measureRows()
    this.prepareRecentLayout()

  }

  prepareRecentLayout(): void {
    if (this.loading || this.recentLayoutReady || this.recentLayoutPending || this.listHeight <= 0) return
    this.recentLayoutPending = true
    // 主列表首次测量完成后再插入近期整段，避免零行高留白先把分隔栏画到错误位置。
    this.getUIContext().postFrameCallback(new InboxLayoutFrame((): void => {
      this.recentLayoutPending = false
      if (this.visible && !this.loading) this.recentLayoutReady = true
    }))
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      AppShell({ title: '收件箱', titleIcon: $r('app.media.nav_inbox'),
        activeRoute: 'pages/Inbox', drawerOpen: $drawerOpen,
        pullToSync: true, pullDisabled: this.selection.selecting, busy: this.actionBusy || this.selection.busy || this.selection.starting }) {
        Column() {
          if (this.loading) {
            NotificationEmptyState({ title: '正在读取收件箱', busy: true })
          } else {
            List({ scroller: this.listScroller }) {
              if (this.showNotifications) {
                ListItem() { CoreNotificationsView({ horizontalInset: 12 }) }.fullWidthItem()
              }
              if (this.records.length === 0) {
                ListItem() {
                  Column({ space: 8 }) {
                    Text(this.message || '收件箱没有记录')
                      .fontSize(18).fontColor(this.message ? UiColor.error : UiColor.secondary)
                      .width('100%').textAlign(TextAlign.Center)
                    if (this.message) {
                      Button('重试').height(40).onClick((): void => { this.loadRecords(true) })
                    } else if (this.needsConfiguration) {
                      Button('前往设置').height(40).onClick((): void => {
                        PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/Settings', params: { section: '文件入口' } })
                      })
                    }
                  }.padding(16).width('100%')
                    .constraintSize({ minHeight: Math.max(80, this.listHeight * (this.recentGroups.length > 0 ? 0.75 : 1)) })
                    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                }.fullWidthItem()
              }
              ForEach(this.records, (record: CoreTask) => {
                TaskSwipeItem({ dataSet: this.taskDataSet(), taskId: this.taskDataSet().taskKey(record.id),
                  readOnly: !this.pageReady, interactionEnabled: !this.selection.starting, itemId: `inbox_record_${record.id}`, listOutset: 12,
                  busy: this.selection.selecting || this.actionBusy || this.selection.starting || this.selection.busy,
                  rightSwipeAction: this.actionPolicy.rightSwipeAction, singleOperations: this.actionPolicy.singleOperations,
                  scrollHost: this.listScroller, scrollHostId: 'inbox_task_list', selection: this.selection, menuIdPrefix: 'inbox_swipe',
                  content: (controller: TaskEditorController): void => { this.recordContent(record, controller) } })
              }, (record: CoreTask) => this.taskDataSet().taskKey(record.id))
              if (this.recentLayoutReady && this.recentGroups.length > 0) {
                if (this.records.length > 0) {
                  ListItem() {
                    Column().width('100%').height(unplannedSpacer(this.listHeight, this.rowTotalHeight))
                  }.fullWidthItem()
                }
                ListItem() { this.plannedDivider() }.fullWidthItem()
                ListItem() { Column().height(16).width('100%') }.fullWidthItem()
                ForEach(this.recentGroups, (day: RecentDay) => {
                  ListItem() { this.recentHeader(day) }.fullWidthItem()
                  ForEach(day.groups, (group: RecentTaskGroup) => {
                    this.recentRegion(group)
                  }, (group: RecentTaskGroup) => JSON.stringify(group))
                  ListItem() { Column().height(16).width('100%') }.fullWidthItem()
                }, (day: RecentDay) => JSON.stringify(day))
              }
              if (this.recentLayoutReady && this.recentMessage) {
                ListItem() {
                  Text(this.recentMessage + '，点击重试').fontSize(14).fontColor(UiColor.error).padding(16)
                    .onClick((): void => { this.loadRecords(true) })
                }.fullWidthItem()
              }
              ListItem() { Column().height(this.selection.selecting ? 156 : 104) }.fullWidthItem()
            }.id('inbox_task_list').width('100%').padding({ left: 12, right: 12 })
              .clipContent(ContentClipMode.BOUNDARY)
              .scrollBar(BarState.Off)
              .layoutWeight(1).enableScrollInteraction(!this.checklistDragging)
              .onAreaChange((oldArea: Area, newArea: Area): void => {
                this.listHeight = parseFloat(newArea.height.toString())
                this.prepareRecentLayout()
              })
              .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
              .edgeEffect(EdgeEffect.None)
          }
        }.width('100%').height('100%')
      }
      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.ui_add_primary')).width(28).height(28)
      }.id('inbox_capture').width(56).height(56).backgroundColor(UiColor.primary)
        .shadow({ radius: 12, color: '#33000000', offsetY: 4 }).margin({ bottom: 24 })
        .visibility(!this.pageReady || this.needsConfiguration || this.drawerOpen || this.captureOpen || this.inlineTyping ||
          this.selection.selecting || this.selection.starting ? Visibility.Hidden : Visibility.Visible)
        .enabled(!this.actionBusy).accessibilityText('记一条')
        .onClick((): void => { this.capture() })
      TaskSelectionToolbar({ selection: this.selection, operations: this.actionPolicy.bulkOperations, idPrefix: 'inbox' })
      if (this.captureOpen) {
        Column().width('100%').height('100%').backgroundColor('#66000000')
          .accessibilityText('关闭并保留草稿').onClick((): void => { this.closeCapture() })
        Column({ space: 12 }) {
          TextInput({ text: this.captureTitle, placeholder: '记下一件事…' }).id('inbox_capture_title').height(60)
            .fontSize(20).fontColor(UiColor.text).placeholderColor(UiColor.secondary).backgroundColor(UiColor.field)
            .borderRadius(12).enterKeyType(EnterKeyType.Done)
            .enabled(!this.captureSaving)
            .onAppear((): void => { this.focusCapture() })
            .onChange((value: string): void => { this.captureTitle = value })
            .onSubmit((): void => { this.saveCapture() })
          if (this.captureMessage.length > 0) {
            Text(this.captureMessage).width('100%').fontSize(13).fontColor(UiColor.error)
          }
          Button(this.captureSaving ? '保存中…' : '保存').id('inbox_capture_save')
            .width('100%').height(48).fontColor(UiColor.onPrimary).backgroundColor(UiColor.primary)
            .enabled(!this.captureSaving && this.captureTitle.trim().length > 0)
            .onClick((): void => { this.saveCapture() })
        }.width('100%').constraintSize({ maxWidth: 560 }).padding(16)
          .backgroundColor(UiColor.surface).borderRadius({ topLeft: 20, topRight: 20 })
          .onClick((): void => {})
      }
    }.width('100%').height('100%')
  }
}
