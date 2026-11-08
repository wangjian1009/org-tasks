import { taskRenderKey } from '../ui/TaskPresentation'
import { UiColor } from '../ui/Theme'
import { KeyboardAvoidMode } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/Controls'
import { TaskListItem } from '../components/TaskListItem'
import { InboxTargetPopup } from '../components/InboxTargetPopup'
import { InboxSwipeActions } from '../components/InboxSwipeActions'
import { InboxService, InboxAction } from '../services/InboxService'
import { RefileSection, RecentDay, refileSections, recentDays, unplannedSpacer, targetPopupHeight } from '../ui/InboxPresentation'
import { AppConfigService } from '../services/AppConfigService'
import { CaptureService } from '../services/CaptureService'
import { FileTargetService } from '../services/FileTargetService'
import { CoreBridgeError, CoreTask, CoreRefileTarget, coreErrorMessage } from '../services/NativeCoreService'

@Entry
@Component
struct Inbox {
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
  private refreshTimer: number = -1
  private visible: boolean = true
  private targetRequest: number = 0
  private actionTimer: number = -1
  private listScroller: ListScroller = new ListScroller()
  private rowHeights: Map<string, number> = new Map()
  private requestId: number = 0
  private captureFocusTimer: number = -1
  private keyboardAvoidMode: KeyboardAvoidMode = KeyboardAvoidMode.OFFSET

  onPageShow() { this.visible = true; this.loadRecords() }
  onPageHide() { this.visible = false; clearTimeout(this.refreshTimer); clearTimeout(this.actionTimer); this.closeTargetPopup() }
  aboutToDisappear() {
    clearTimeout(this.captureFocusTimer)
    clearTimeout(this.actionTimer)
    this.visible = false
    clearTimeout(this.refreshTimer)
    ++this.targetRequest
    if (this.captureOpen) this.getUIContext().setKeyboardAvoidMode(this.keyboardAvoidMode)
  }

  onBackPress(): boolean {
    if (this.captureOpen) { this.closeCapture(); return true }
    if (this.selected) { this.closeTargetPopup(); return true }
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  drawerChanged() { if (this.drawerOpen) this.closeTargetPopup() }

  selectRecord(record: CoreTask) {
    if (this.actionBusy || this.drawerOpen || this.captureOpen) return
    this.selected = record
    this.popupMessage = ''
    this.loadTargets()
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
    if (this.actionBusy || this.drawerOpen || this.captureOpen) return
    const node = this.getUIContext().getFrameNodeById(`inbox_record_${record.id}`)
    if (node) ListItemSwipeActionManager.collapse(node)
    this.listScroller.closeAllSwipeActions()
    clearTimeout(this.actionTimer)
    // 正文触发的程序化侧滑不会触发 ListScroller 的完成回调，待归位后再锚定浮层。
    this.actionTimer = setTimeout((): void => {
      if (!this.visible) return
      if (action === 'move') this.selectRecord(record)
      else if (action === 'delete') this.confirmDelete(record)
      else this.perform(action, undefined, record)
    }, 260)
  }

  swipeRecord(record: CoreTask, left: boolean) {
    if (this.actionBusy || this.selected || this.drawerOpen || this.captureOpen) return
    const node = this.getUIContext().getFrameNodeById(`inbox_record_${record.id}`)
    if (!node) return
    if (left) ListItemSwipeActionManager.expand(node, ListItemSwipeActionDirection.END)
    else ListItemSwipeActionManager.collapse(node)
  }

  @Builder
  swipeMenu(record: CoreTask) {
    InboxSwipeActions({ busy: this.actionBusy,
      move: (): void => { this.swipeAction(record, 'move') },
      someday: (): void => { this.swipeAction(record, 'someday') },
      memo: (): void => { this.swipeAction(record, 'memo') },
      remove: (): void => { this.swipeAction(record, 'delete') } })
  }

  @Builder
  targetPopup() {
    InboxTargetPopup({ sections: this.targetSections,
      selectionKey: this.selected ? JSON.stringify(this.selected.fullPath) : '',
      loading: this.targetsLoading, busy: this.actionBusy, message: this.popupMessage,
      choose: (target: CoreRefileTarget): void => { this.perform('move', target) },
      retry: (): void => { this.loadRecords() } })
      .width(this.popupWidth)
      .height(targetPopupHeight(this.targetSections, this.listHeight, this.targetsLoading, this.popupMessage, this.actionBusy))
  }

  async loadTargets() {
    if (!this.selected || this.actionBusy) return
    const request = ++this.targetRequest
    this.targetsLoading = true
    this.popupMessage = ''
    try {
      const targets = await InboxService.targets(this.getUIContext().getHostContext()!)
      if (request === this.targetRequest) {
        this.targetSections = refileSections(targets.targets)
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

  confirmDelete(record: CoreTask) {
    if (this.actionBusy) return
    this.getUIContext().showAlertDialog({ title: '删除这条记录？', message: `“${record.heading}”及其子记录将从文件中删除。`,
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除', action: (): void => { this.perform('delete', undefined, record) } } })
  }

  async perform(action: InboxAction, target?: CoreRefileTarget, record?: CoreTask) {
    const selected = record || this.selected
    if (!selected || this.actionBusy) return
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
      else this.getUIContext().getPromptAction().showToast({ message, duration: 3000 })
    } finally { this.actionBusy = false }
  }

  capture() {
    if (this.captureOpen || this.drawerOpen || this.actionBusy) return
    this.keyboardAvoidMode = this.getUIContext().getKeyboardAvoidMode()
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE)
    this.captureMessage = ''
    this.captureOpen = true
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

  async loadRecentRecords(request: number) {
    this.recentLoading = this.recentGroups.length === 0
    this.recentMessage = ''
    try {
      const tasks = await InboxService.recent(this.getUIContext().getHostContext()!)
      if (request === this.requestId) this.recentGroups = recentDays(tasks)
    } catch (e) {
      if (request === this.requestId) this.recentMessage = `近期记录读取失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally {
      if (request === this.requestId) this.recentLoading = false
    }
  }

  @Builder
  plannedDivider() {
    Column() {
      Divider().color('#606D64').margin({ left: 20, right: 20 })
      Row({ space: 10 }) {
        Row().width(3).height(18).backgroundColor(UiColor.primary)
        Text('已规划').fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.primary)
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

  async loadRecords() {
    const request = ++this.requestId
    clearTimeout(this.refreshTimer)
    this.loadRecentRecords(request)
    this.loading = this.records.length === 0
    this.message = ''
    this.needsConfiguration = false
    try {
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      const result = await FileTargetService.query(config, 'inbox')
      if (request !== this.requestId) return
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
        else { this.selected = selected; this.loadTargets() }
      }
    } catch (e) {
      if (request === this.requestId) {
        this.closeTargetPopup()
        this.records = []
        this.message = `读取收件箱失败：${coreErrorMessage(e as CoreBridgeError)}`
      }
    } finally {
      if (request === this.requestId) {
        this.loading = false
        if (this.visible) this.refreshTimer = setTimeout((): void => { this.loadRecords() }, 60000)
      }
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      AppShell({ title: '收件箱', titleIcon: $r('app.media.nav_inbox'), synchronized: (): void => { this.loadRecords() }, activeRoute: 'pages/Inbox', drawerOpen: $drawerOpen, pullToSync: true, busy: this.actionBusy }) {
        Column() {
          if (this.loading && this.recentGroups.length === 0) {
            EmptyState({ title: '正在读取收件箱', busy: true })
          } else {
            List({ scroller: this.listScroller }) {
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
                }
              }
              ForEach(this.records, (record: CoreTask) => {
                ListItem() {
                  Row() {
                    TaskListItem({ task: record, enableSwipeActions: true,
                      swipe: (left: boolean): void => { this.swipeRecord(record, left) }, open: (): void => {
                      this.getUIContext().getRouter().pushUrl({ url: 'pages/TaskEdit', params: { task: record } })
                    } })
                  }.width('100%').padding({ left: 12, right: 12 })
                    .backgroundColor(this.selected?.id === record.id ? '#323D3A' : Color.Transparent)
                    .borderRadius(12).border({ width: this.selected?.id === record.id ? 1 : 0, color: UiColor.primary })
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
                }.id(`inbox_record_${record.id}`).swipeAction({ end: this.swipeMenu(record), edgeEffect: SwipeEdgeEffect.None })
              }, (record: CoreTask) => taskRenderKey(record))
              if (this.records.length > 0 || this.recentGroups.length > 0) {
                ListItem() {
                  Column().width('100%').height(unplannedSpacer(this.listHeight,
                    this.records.length > 0 ? this.rowTotalHeight : this.emptyHeight))
                }
              }
              if (this.recentGroups.length > 0) {
                ListItem() { this.plannedDivider() }
                ListItem() { Column().height(16).width('100%').backgroundColor('#282C29') }
                ForEach(this.recentGroups, (day: RecentDay) => {
                  ListItemGroup({ header: this.recentHeader(day) }) {
                    ForEach(day.tasks, (task: CoreTask) => {
                      ListItem() {
                        Row() {
                          TaskListItem({ task, open: (): void => {
                            this.getUIContext().getRouter().pushUrl({ url: 'pages/TaskEdit', params: { task } })
                          } })
                        }.width('100%').padding({ left: 12, right: 12 }).backgroundColor('#282C29')
                      }
                    }, (task: CoreTask) => taskRenderKey(task))
                    ListItem() { Column().height(16).width('100%').backgroundColor('#282C29') }
                  }
                }, (day: RecentDay) => JSON.stringify(day))
              }
              if (this.recentLoading) {
                ListItem() { Text('正在读取近期记录…').fontSize(14).fontColor(UiColor.secondary).padding(16) }
              }
              if (this.recentMessage) {
                ListItem() {
                  Text(this.recentMessage + '，点击重试').fontSize(14).fontColor(UiColor.error).padding(16)
                    .onClick((): void => { this.loadRecords() })
                }
              }
              ListItem() { Column().height(104) }
            }.width('100%').layoutWeight(1)
              .onAreaChange((oldArea: Area, newArea: Area): void => {
                this.listHeight = parseFloat(newArea.height.toString())
                this.popupWidth = Math.min(350, Math.max(0, parseFloat(newArea.width.toString()) - 40))
              })
              .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
              .edgeEffect(EdgeEffect.None)
          }
        }.width('100%').height('100%')
      }
      if (!this.drawerOpen && !this.captureOpen && !this.selected) {
        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.ui_add_primary')).width(28).height(28)
        }.id('inbox_capture').width(56).height(56).backgroundColor(UiColor.primary)
          .shadow({ radius: 12, color: '#33000000', offsetY: 4 }).margin({ bottom: 24 })
          .accessibilityText('记一条')
          .onClick((): void => { this.capture() })
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
