import { TaskInlineSession, TaskInlineService } from '../services/TaskInlineService'
import { NotificationEmptyState } from '../components/NotificationEmptyState'
import { CoreNotificationsView } from '../components/CoreNotificationsView'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/CoreNotificationService'
import { taskRenderKey } from '../ui/TaskPresentation'
import { UiColor } from '../ui/Theme'
import { KeyboardAvoidMode } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/Controls'
import { TaskListItem } from '../components/TaskListItem'
import { TaskRegion } from '../components/TaskRegion'
import { RegionAreaPolicy, TaskDateDisplay } from '../ui/TaskListPresentation'
import { MoveToTarget } from '../components/MoveToTarget'
import { TaskSwipeActions } from '../components/TaskSwipeActions'
import { TaskSelectionRow } from '../components/TaskSelectionRow'
import { TaskBatchToolbar } from '../components/TaskBatchToolbar'
import { TaskPageActionPolicy, taskPageActionPolicy, taskSwipeMenu, taskBatchMenu, TaskSwipeAction, TaskBatchAction } from '../ui/TaskActionPresentation'
import { OrgContentView } from '../components/OrgContentView'
import { InboxService, InboxAction } from '../services/InboxService'
import { MoveToTargetService } from '../services/MoveToTargetService'
import { RecentDay, RecentTaskGroup, recentDays, unplannedSpacer } from '../ui/InboxPresentation'
import { RefileSection, refileSections, targetPopupHeight } from '../ui/MoveToTargetPresentation'
import { AppConfigService } from '../services/AppConfigService'
import { CaptureService } from '../services/CaptureService'
import { CoreBridgeError, CoreTask, CoreTaskPath, CoreRefileTarget, coreErrorMessage } from '../services/NativeCoreService'

@Entry
@Component
struct Inbox {
  @StorageLink('coreNotifications') notificationState: CoreNotificationsState = emptyCoreNotificationsState()
  @State records: CoreTask[] = []
  @State recentGroups: RecentDay[] = []
  @State recentLoading: boolean = true
  @State recentMessage: string = ''
  @State rowTotalHeight: number = 0
  @State emptyHeight: number = 80
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
  @State selected: CoreTask | undefined = undefined
  @State targetSections: RefileSection[] = []
  @State targetsLoading: boolean = false
  @State popupMessage: string = ''
  @State actionBusy: boolean = false
  @State popupWidth: number = 350
  @State listHeight: number = 0
  @State selectingRecords: boolean = false
  @State selectedRecordIds: string[] = []
  @State selectionStarting: boolean = false
  @State mergeBusy: boolean = false
  @State mergeMessage: string = ''
  @State mergeInvalid: boolean = false
  @State mergedPath: string = ''
  private mergeFocusTimer: number = -1
  private refreshTimer: number = -1
  private visible: boolean = true
  private targetRequest: number = 0
  private actionTimer: number = -1
  private actionPolicy: TaskPageActionPolicy = taskPageActionPolicy('inbox')
  private recentActionPolicy: TaskPageActionPolicy = taskPageActionPolicy('recent')
  private listScroller: ListScroller = new ListScroller()
  private rowHeights: Map<string, number> = new Map()
  private requestId: number = 0
  private captureFocusTimer: number = -1
  private keyboardAvoidMode: KeyboardAvoidMode = KeyboardAvoidMode.OFFSET

  onPageShow() { this.visible = true }
  onPageHide() { this.visible = false; clearTimeout(this.refreshTimer); clearTimeout(this.actionTimer); clearTimeout(this.mergeFocusTimer); this.closeTargetPopup(); if (!this.mergeBusy) this.resetSelection() }
  aboutToDisappear() {
    clearTimeout(this.captureFocusTimer)
    clearTimeout(this.actionTimer)
    clearTimeout(this.mergeFocusTimer)
    this.visible = false
    clearTimeout(this.refreshTimer)
    ++this.targetRequest
    if (this.captureOpen) this.getUIContext().setKeyboardAvoidMode(this.keyboardAvoidMode)
  }

  onBackPress(): boolean {
    if (this.mergeBusy || this.selectionStarting) return true
    if (this.selectingRecords) { this.cancelSelection(); return true }
    if (TaskInlineSession.active()) { TaskInlineSession.end(!AppStorage.get<boolean>('taskInlineTyping')); return true }
    if (this.captureOpen) { this.closeCapture(); return true }
    if (this.selected) { this.closeTargetPopup(); return true }
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  drawerChanged() { if (this.drawerOpen) { this.closeTargetPopup(); if (this.selectingRecords && !this.mergeBusy) this.cancelSelection() } }

  selectedRecords(): CoreTask[] {
    const result: CoreTask[] = []
    for (const id of this.selectedRecordIds) {
      const record = this.records.find(item => item.id === id)
      if (record) result.push(record)
    }
    return result
  }

  async startSelection(record: CoreTask) {
    if (!this.actionPolicy.batchEditing || this.checklistDragging) return
    if (this.selectingRecords || this.mergeBusy || this.actionBusy || this.selectionStarting || this.drawerOpen || this.captureOpen || this.loading) return
    this.selectionStarting = true
    clearTimeout(this.actionTimer)
    try {
      if (!await TaskInlineSession.end(true)) return
      this.closeTargetPopup()
      try {
        this.listScroller.closeAllSwipeActions()
      } catch (_) {
        // 尚未完成布局时没有需要关闭的侧滑操作。
      }
      await this.loadRecords()
      if (!this.visible || this.needsConfiguration || this.message) return
      if (!this.records.some(item => item.id === record.id)) return
      this.selectingRecords = true
      this.selectedRecordIds = [record.id]
      this.mergeMessage = ''
      this.mergeInvalid = false
      this.mergedPath = ''
      clearTimeout(this.refreshTimer)
    } finally { this.selectionStarting = false }
  }

  resetSelection() {
    this.selectingRecords = false
    this.selectedRecordIds = []
    this.mergeMessage = ''
    this.mergeInvalid = false
  }

  cancelSelection() {
    if (this.mergeBusy) return
    this.resetSelection()
    if (this.visible) this.loadRecords()
  }

  toggleRecord(record: CoreTask) {
    if (this.mergeBusy) return
    this.selectedRecordIds = this.selectedRecordIds.includes(record.id) ?
      this.selectedRecordIds.filter(id => id !== record.id) : [...this.selectedRecordIds, record.id]
  }

  async mergeSelected() {
    const records = this.selectedRecords()
    if (!this.actionPolicy.batchEditing || !this.actionPolicy.batchActions.includes('merge') || records.length < 2 || this.mergeBusy || this.mergeInvalid) return
    this.mergeBusy = true
    this.mergeMessage = ''
    let merged: CoreTaskPath
    try {
      merged = await InboxService.merge(this.getUIContext().getHostContext()!, records)
    } catch (e) {
      this.mergeBusy = false
      this.mergeMessage = coreErrorMessage(e as CoreBridgeError)
      this.mergeInvalid = (e as CoreBridgeError).code === 'invalidState'
      return
    }
    // 一组已经提交；刷新失败只重新读取，不能再次删除或修改原记录。
    this.mergeBusy = false
    this.resetSelection()
    this.mergedPath = JSON.stringify(merged)
    try { this.getUIContext().getPromptAction().showToast({ message: `已合并 ${records.length} 条记录` }) }
    catch (_) { /* 成功提示失败不能阻止读取已提交的结果。 */ }
    await this.loadRecords()
    const index = this.records.findIndex(item => JSON.stringify(item.fullPath) === this.mergedPath)
    if (index >= 0) {
      clearTimeout(this.mergeFocusTimer)
      this.mergeFocusTimer = setTimeout((): void => {
        if (this.visible && !this.selectingRecords) {
          try { this.listScroller.scrollToIndex(index + (this.notificationState.notifications.length > 0 ? 1 : 0), true, ScrollAlign.CENTER) }
          catch (_) { /* 尚未布局时保留结果高亮。 */ }
        }
      }, 100)
    }
  }

  selectRecord(record: CoreTask) {
    if (this.actionBusy || this.drawerOpen || this.captureOpen || this.selectingRecords) return
    this.selected = record
    this.popupMessage = ''
    this.loadTargets()
  }

  async prepareAction(record: CoreTask, action: InboxAction) {
    if (this.actionBusy || this.drawerOpen || this.captureOpen || this.selectingRecords || this.selectionStarting) return
    this.actionBusy = true
    try {
      if (!await TaskInlineSession.end(false) || !this.visible) return
      const current = await TaskInlineService.find(this.getUIContext().getHostContext()!, record)
      if (!current || !this.visible) return
      this.actionBusy = false
      if (action === 'move') this.selectRecord(current)
      else if (action === 'delete') this.confirmDelete(current)
      else await this.perform(action, undefined, current)
    } catch (e) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: coreErrorMessage(e as CoreBridgeError), duration: 3000 })
      } catch (_) {
        // 页面退出时提示可能不可用。
      }
    } finally { this.actionBusy = false }
  }

  closeTargetPopup() {
    if (this.actionBusy) return
    ++this.targetRequest
    this.selected = undefined
    this.targetSections = []
    this.popupMessage = ''
    this.targetsLoading = false
  }

  swipeAction(record: CoreTask, action: InboxAction) {
    if (this.actionBusy || this.drawerOpen || this.captureOpen || this.selectingRecords || this.selectionStarting ||
      this.mergeBusy || this.checklistDragging || this.inlineTyping || this.selected) return
    const node = this.getUIContext().getFrameNodeById(`inbox_record_${record.id}`)
    try {
      if (node) ListItemSwipeActionManager.collapse(node)
    } catch (_) {
      // 节点已销毁时忽略归位操作。
    }
    try {
      this.listScroller.closeAllSwipeActions()
    } catch (_) {
      // 尚未完成布局时没有需要关闭的侧滑操作。
    }
    clearTimeout(this.actionTimer)
    // 正文触发的程序化侧滑不会触发 ListScroller 的完成回调，待归位后再锚定浮层。
    this.actionTimer = setTimeout((): void => {
      if (!this.visible) return
      this.prepareAction(record, action)
    }, 260)
  }

  swipeRecord(record: CoreTask, left: boolean) {
    if (this.actionBusy || this.selected || this.drawerOpen || this.captureOpen || this.selectingRecords || this.selectionStarting) return
    const node = this.getUIContext().getFrameNodeById(`inbox_record_${record.id}`)
    if (!node) return
    if (left) {
      try {
        ListItemSwipeActionManager.expand(node, ListItemSwipeActionDirection.END)
      } catch (_) {
        // 节点已销毁时忽略展开操作。
      }
    }
    else this.swipeAction(record, 'move')
  }

  @Builder
  swipeMenu(record: CoreTask) {
    TaskSwipeActions({ busy: this.actionBusy || this.selectionStarting || this.mergeBusy, idPrefix: 'inbox_swipe',
      items: taskSwipeMenu(this.actionPolicy, (action: TaskSwipeAction): void => {
        if (action === 'select') this.startSelection(record)
        else this.swipeAction(record, action)
      }) })
  }

  @Builder
  swipeMoveIndicator() {
    // 右滑只作为直接移动手势，不显示额外提示栏。
    Row().width(1).height(1).opacity(0)
  }

  @Builder
  targetPopup() {
    MoveToTarget({ sections: this.targetSections,
      selectionKey: this.selected ? JSON.stringify([this.selected.fullPath, this.selected.fileVersion]) : '',
      loading: this.targetsLoading, busy: this.actionBusy, message: this.popupMessage,
      choose: (target: CoreRefileTarget): void => { this.perform('move', target) },
      retry: (): void => { this.refreshMoveTargets() } })
      .width(this.popupWidth)
      .height(targetPopupHeight(this.targetSections, this.listHeight, this.targetsLoading, this.popupMessage, this.actionBusy))
  }

  async loadTargets() {
    if (!this.selected || this.actionBusy) return
    const request = ++this.targetRequest
    this.targetsLoading = true
    this.popupMessage = ''
    try {
      const targets = await MoveToTargetService.targets(this.getUIContext().getHostContext()!)
      if (request === this.targetRequest) {
        this.targetSections = refileSections(targets)
      }
    } catch (e) {
      if (request === this.targetRequest) {
        this.targetSections = []
        this.popupMessage = coreErrorMessage(e as CoreBridgeError)
      }
    } finally {
      if (request === this.targetRequest) this.targetsLoading = false
    }
  }

  async refreshMoveTargets() {
    if (!this.selected || this.actionBusy || this.targetsLoading) return
    const request = ++this.targetRequest
    this.actionBusy = true
    this.popupMessage = ''
    try {
      const current = await TaskInlineService.find(this.getUIContext().getHostContext()!, this.selected)
      if (request !== this.targetRequest || !this.visible) return
      this.actionBusy = false
      if (!current) { this.closeTargetPopup(); return }
      this.selected = current
      await this.loadTargets()
    } catch (e) {
      if (request === this.targetRequest) this.popupMessage = coreErrorMessage(e as CoreBridgeError)
    } finally { this.actionBusy = false }
  }

  confirmDelete(record: CoreTask) {
    if (this.actionBusy) return
    this.getUIContext().showAlertDialog({ title: '删除这条记录？', message: `“${record.heading}”及其子记录将从文件中删除。`,
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除', fontColor: UiColor.error, action: (): void => { this.perform('delete', undefined, record) } } })
  }

  async perform(action: InboxAction, target?: CoreRefileTarget, record?: CoreTask) {
    const selected = record || this.selected
    if (!selected || this.actionBusy || this.selectingRecords || this.selectionStarting) return
    this.actionBusy = true
    this.popupMessage = ''
    ++this.targetRequest
    this.targetsLoading = false
    try {
      await InboxService.perform(this.getUIContext().getHostContext()!, selected, action, target)
      this.actionBusy = false
      this.closeTargetPopup()
      await this.loadRecords()
    } catch (e) {
      const message = coreErrorMessage(e as CoreBridgeError)
      if (this.selected) this.popupMessage = message
      else {
        try {
          this.getUIContext().getPromptAction().showToast({ message, duration: 3000 })
        } catch (_) {
          // 页面退出时提示可能不可用。
        }
      }
    } finally { this.actionBusy = false }
  }

  async capture() {
    if (this.captureOpen || this.drawerOpen || this.actionBusy || this.selectingRecords || this.selectionStarting) return
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
    if (this.captureSaving) return
    const title = this.captureTitle.trim()
    if (!title) {
      this.captureMessage = '请输入标题'
      return
    }
    this.captureSaving = true
    this.captureMessage = ''
    try {
      await CaptureService.save(this.getUIContext().getHostContext()!, title)
      this.captureSaving = false
      this.closeCapture()
      this.captureTitle = ''
      await this.loadRecords()
    } catch (e) {
      this.captureMessage = `保存失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally {
      this.captureSaving = false
    }
  }

  measureRows() {
    let total = 0
    for (const record of this.records) total += this.rowHeights.get(record.id) || 0
    if (total !== this.rowTotalHeight) this.rowTotalHeight = total
  }

  @Builder
  plannedDivider() {
    Column() {
      Divider().color('#606D64').margin({ left: 20, right: 20 })
      Row({ space: 10 }) {
        Row().width(3).height(18).backgroundColor(UiColor.primary)
        Text('最近新增').fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.primary)
        Divider().layoutWeight(1).color('#4C5951')
      }.height(52).width('100%').padding({ left: 20, right: 20 })
    }.width('100%').backgroundColor('#242925')
  }

  @Builder
  recentHeader(day: RecentDay) {
    Row({ space: 8 }) {
      Text(day.date).fontSize(25).fontWeight(FontWeight.Bold).fontColor(UiColor.text).flexShrink(0)
      Text(day.weekday).fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiColor.secondary).flexShrink(0)
      Divider().layoutWeight(1).color(UiColor.outline).strokeWidth(0.5)
    }.width('100%').height(48).padding({ left: 20, right: 20 }).backgroundColor('#282C29')
  }

  @Builder
  recentTask(task: CoreTask) {
    TaskListItem({ task, dateDisplay: TaskDateDisplay.Creation, regionAreaPolicy: RegionAreaPolicy.None, rightSwipeAction: this.recentActionPolicy.rightSwipeAction, scrollHost: this.listScroller, scrollHostId: 'inbox_task_list', open: (): void => {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/TaskEdit', params: { task } })
    } }).enabled(!this.selectingRecords && !this.mergeBusy)
  }

  @Builder
  recentRegion(group: RecentTaskGroup) {
    TaskRegion({ category: group.category || '未分类', project: group.kind === 'project' ? group : null }) {
      ForEach(group.items, (task: CoreTask) => {
        ListItem() { this.recentTask(task) }
      }, (task: CoreTask) => taskRenderKey(task))
    }
  }

  // 分组由 List 的内边距定位；通栏条目扩展回页面宽度，避免包装原生列表分组。
  @Styles
  fullWidthItem() {
    .width('calc(100% + 40vp)').margin({ left: -20, right: -20 })
  }

  async loadRecords() {
    if (TaskInlineSession.active() || this.selectingRecords || this.mergeBusy) return
    const request = ++this.requestId
    clearTimeout(this.refreshTimer)
    this.recentLoading = this.recentGroups.length === 0
    this.recentMessage = ''
    this.loading = this.records.length === 0
    this.message = ''
    this.needsConfiguration = false
    try {
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      const snapshot = await InboxService.load(config)
      const result = snapshot.inbox
      if (request !== this.requestId) return
      this.recentGroups = recentDays(snapshot.recent)
      if (!result) {
        this.closeTargetPopup()
        this.needsConfiguration = true
        this.records = []
        return
      }
      this.records = result.tasks
      this.measureRows()
      if (this.selected) {
        const selected = this.records.find((record: CoreTask) => record.id === this.selected?.id)
        if (!selected) this.closeTargetPopup()
        else this.selected = selected
      }
    } catch (e) {
      if (request === this.requestId) {
        this.closeTargetPopup()
        this.records = []
        this.message = `读取收件箱失败：${coreErrorMessage(e as CoreBridgeError)}`
        this.recentGroups = []
        this.recentMessage = `近期记录读取失败：${coreErrorMessage(e as CoreBridgeError)}`
      }
    } finally {
      if (request === this.requestId) {
        this.loading = false
        this.recentLoading = false
        if (this.visible) this.refreshTimer = setTimeout((): void => { this.loadRecords() }, 60000)
      }
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      AppShell({ refreshOnPageShow: true, title: '收件箱', titleIcon: $r('app.media.nav_inbox'),
        actionLabel: this.selectingRecords ? '完成多选并退出' : '', actionText: this.selectingRecords ? '完成' : '',
        actionProminent: this.selectingRecords,
        action: (): void => { this.cancelSelection() },
        synchronized: (): void => { this.loadRecords() }, activeRoute: 'pages/Inbox', drawerOpen: $drawerOpen,
        pullToSync: true, pullDisabled: this.selectingRecords, busy: this.actionBusy || this.mergeBusy || this.selectionStarting }) {
        Column() {
          if (this.loading && this.recentGroups.length === 0) {
            NotificationEmptyState({ title: '正在读取收件箱', busy: true })
          } else {
            List({ scroller: this.listScroller }) {
              if (this.notificationState.notifications.length > 0) {
                ListItem() { CoreNotificationsView({ horizontalInset: 12 }) }.fullWidthItem()
              }
              if (this.records.length === 0) {
                ListItem() {
                  Column({ space: 8 }) {
                    Text(this.needsConfiguration ? '收件箱文件未选择或已失效' : (this.message || '收件箱没有记录'))
                      .fontSize(14).fontColor(this.message ? UiColor.error : UiColor.secondary).width('100%')
                    if (this.needsConfiguration) {
                      Button('前往设置').height(40).onClick((): void => {
                        this.getUIContext().getRouter().pushUrl({ url: 'pages/Settings', params: { section: '笔记与笔记本' } })
                      })
                    } else if (this.message) {
                      Button('重试').height(40).onClick((): void => { this.loadRecords() })
                    }
                  }.padding(16).width('100%').constraintSize({ minHeight: 80 })
                    .onAreaChange((oldArea: Area, newArea: Area): void => { this.emptyHeight = parseFloat(newArea.height.toString()) })
                }.fullWidthItem()
              }
              ForEach(this.records, (record: CoreTask) => {
                ListItem() {
                  Row() {
                    TaskSelectionRow({ batchEditing: this.actionPolicy.batchEditing, selecting: this.selectingRecords,
                      busy: this.mergeBusy || this.actionBusy || this.selectionStarting,
                      selectedIndex: this.selectedRecordIds.indexOf(record.id), heading: record.heading, horizontalInset: 12,
                      highlighted: this.selected?.id === record.id || this.mergedPath === JSON.stringify(record.fullPath),
                      begin: (): void => { this.startSelection(record) }, toggle: (): void => { this.toggleRecord(record) } }) {
                      TaskListItem({ task: record, enableSwipeActions: this.actionPolicy.swipeActions.length > 0, rightSwipeAction: this.actionPolicy.rightSwipeAction, scrollHost: this.listScroller, scrollHostId: 'inbox_task_list',
                        swipe: (left: boolean): void => { this.swipeRecord(record, left) }, open: (): void => {
                          this.getUIContext().getRouter().pushUrl({ url: 'pages/TaskEdit', params: { task: record } })
                        } })
                      if (this.mergedPath === JSON.stringify(record.fullPath) && !this.inlineActive) {
                        OrgContentView({ fragment: record.bodyHtml, empty: false, embedded: true, embeddedPadding: 8 })
                          .width('100%').padding({ left: 27 })
                      }
                    }
                  }.width('100%')
                    .bindPopup(this.selected?.id === record.id, {
                      builder: this.targetPopup, placement: Placement.Bottom, targetSpace: 10,
                      enableArrow: false, width: this.popupWidth, radius: 16,
                      popupColor: '#363A38', backgroundBlurStyle: BlurStyle.NONE,
                      mask: { color: '#2E000000' }, autoCancel: !this.actionBusy,
                      onWillDismiss: !this.actionBusy, focusable: true,
                      onStateChange: (event): void => {
                        if (!event.isVisible && this.selected?.id === record.id) this.closeTargetPopup()
                      }
                    })
                    .onAreaChange((oldArea: Area, newArea: Area): void => {
                      this.rowHeights.set(record.id, parseFloat(newArea.height.toString()))
                      this.measureRows()
                    })
                }.fullWidthItem().id(`inbox_record_${record.id}`).swipeAction(this.selectingRecords || this.actionBusy || this.selectionStarting || this.mergeBusy || this.checklistDragging || !!this.selected || this.inlineTyping ? {} : {
                  start: this.actionPolicy.rightSwipeAction === 'move' ? {
                    builder: (): void => { this.swipeMoveIndicator() }, actionAreaDistance: 48,
                    onAction: (): void => { this.swipeAction(record, 'move') }
                  } : undefined,
                  end: this.actionPolicy.swipeActions.length > 0 ? { builder: (): void => { this.swipeMenu(record) } } : undefined,
                  edgeEffect: SwipeEdgeEffect.None }).enabled(!this.selectionStarting)
              }, (record: CoreTask) => taskRenderKey(record))
              if (this.records.length > 0 || this.recentGroups.length > 0) {
                ListItem() {
                  Column().width('100%').height(unplannedSpacer(this.listHeight,
                    this.records.length > 0 ? this.rowTotalHeight : this.emptyHeight))
                }.fullWidthItem()
              }
              if (this.recentGroups.length > 0) {
                ListItem() { this.plannedDivider() }.fullWidthItem()
                ListItem() { Column().height(16).width('100%').backgroundColor('#282C29') }.fullWidthItem()
                ForEach(this.recentGroups, (day: RecentDay) => {
                  ListItem() { this.recentHeader(day) }.fullWidthItem()
                  ForEach(day.groups, (group: RecentTaskGroup) => {
                    this.recentRegion(group)
                  }, (group: RecentTaskGroup) => JSON.stringify(group))
                  ListItem() { Column().height(16).width('100%').backgroundColor('#282C29') }.fullWidthItem()
                }, (day: RecentDay) => JSON.stringify(day))
              }
              if (this.recentLoading) {
                ListItem() { Text('正在读取近期记录…').fontSize(14).fontColor(UiColor.secondary).padding(16) }.fullWidthItem()
              }
              if (this.recentMessage) {
                ListItem() {
                  Text(this.recentMessage + '，点击重试').fontSize(14).fontColor(UiColor.error).padding(16)
                    .onClick((): void => { this.loadRecords() })
                }.fullWidthItem()
              }
              ListItem() { Column().height(104) }.fullWidthItem()
            }.id('inbox_task_list').width('100%').padding({ left: 20, right: 20 })
              .layoutWeight(1).enableScrollInteraction(!this.checklistDragging)
              .onAreaChange((oldArea: Area, newArea: Area): void => {
                this.listHeight = parseFloat(newArea.height.toString())
                this.popupWidth = Math.min(350, Math.max(0, parseFloat(newArea.width.toString()) - 40))
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
        .visibility(this.drawerOpen || this.captureOpen || this.selected || this.inlineTyping || this.selectingRecords || this.selectionStarting ? Visibility.Hidden : Visibility.Visible)
        .enabled(!this.actionBusy).accessibilityText('记一条')
        .onClick((): void => { this.capture() })
      if (this.selectingRecords && this.actionPolicy.batchEditing) {
        TaskBatchToolbar({ items: taskBatchMenu(this.actionPolicy, (action: TaskBatchAction): void => {
            if (action === 'merge') this.mergeSelected()
          }), count: this.selectedRecordIds.length, busy: this.mergeBusy, busyAction: this.mergeBusy ? 'merge' : '', invalid: this.mergeInvalid,
          message: this.mergeMessage, caption: this.selectedRecordIds.length > 0 ? `合并: ${this.selectedRecords()[0]?.heading || ''}` : '请选择至少两条记录',
          idPrefix: 'inbox', retry: (): void => { this.cancelSelection() } })
      }
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
