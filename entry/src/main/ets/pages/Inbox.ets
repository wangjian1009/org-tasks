import { taskRenderKey } from '../ui/TaskPresentation'
import { UiColor } from '../ui/Theme'
import { KeyboardAvoidMode } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/Controls'
import { TaskListItem } from '../components/TaskListItem'
import { InboxTargetTray } from '../components/InboxTargetTray'
import { InboxService, InboxAction } from '../services/InboxService'
import { RefileSection, RecentDay, refileSections, recentDays, unplannedSpacer } from '../ui/InboxPresentation'
import { InboxListItem } from '../components/InboxListItem'
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
  @State trayMessage: string = ''
  @State trayBusy: boolean = false
  @State trayHeight: number = 0
  private contentHeight: number = 760
  @State listHeight: number = 0
  private refreshTimer: number = -1
  private visible: boolean = true
  private expandedTray: boolean = false
  private targetRequest: number = 0
  private trayGeneration: number = 0
  private revealUntil: number = 0
  private revealTimer: number = -1
  private listScroller: Scroller = new Scroller()
  private rowHeights: Map<string, number> = new Map()
  private requestId: number = 0
  private captureFocusTimer: number = -1
  private keyboardAvoidMode: KeyboardAvoidMode = KeyboardAvoidMode.OFFSET

  onPageShow() { this.visible = true; this.loadRecords() }
  onPageHide() { this.visible = false; clearTimeout(this.refreshTimer) }
  aboutToDisappear() {
    clearTimeout(this.captureFocusTimer)
    this.visible = false
    clearTimeout(this.refreshTimer)
    clearTimeout(this.revealTimer)
    ++this.targetRequest
    if (this.captureOpen) this.getUIContext().setKeyboardAvoidMode(this.keyboardAvoidMode)
  }

  onBackPress(): boolean {
    if (this.captureOpen) { this.closeCapture(); return true }
    if (this.selected) { this.closeTray(); return true }
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  drawerChanged() { if (this.drawerOpen) this.closeTray() }

  revealSelected() {
    if (!this.selected || Date.now() > this.revealUntil) return
    clearTimeout(this.revealTimer)
    this.revealTimer = setTimeout((): void => {
      if (!this.selected) return
      const index = this.records.findIndex((record: CoreTask) => record.id === this.selected?.id)
      if (index < 0) return
      const height = this.rowHeights.get(this.selected.id) || 80
      this.listScroller.scrollToIndex(index, false, height > this.listHeight - 32 ? ScrollAlign.START : ScrollAlign.AUTO)
    }, 0)
  }

  resizeTray(expanded: boolean) {
    if (this.trayBusy) return
    this.expandedTray = expanded
    this.revealUntil = Date.now() + 800
    const height = Math.max(160, Math.min(expanded ? 540 : 420, this.contentHeight - 176))
    this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseInOut }, (): void => { this.trayHeight = height })
    this.revealSelected()
  }

  selectRecord(record: CoreTask) {
    if (this.trayBusy || this.drawerOpen || this.captureOpen) return
    if (this.selected?.id === record.id && this.trayHeight > 0) return
    ++this.trayGeneration
    this.selected = record
    this.trayMessage = ''
    this.resizeTray(this.expandedTray)
    this.loadTargets()
  }

  closeTray() {
    if (this.trayBusy) return
    const generation = ++this.trayGeneration
    ++this.targetRequest
    this.revealUntil = 0
    this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseInOut,
      onFinish: (): void => {
        if (generation === this.trayGeneration) {
          this.selected = undefined
          this.targetSections = []
          this.expandedTray = false
        }
      } }, (): void => { this.trayHeight = 0 })
  }

  async loadTargets() {
    if (!this.selected || this.trayBusy) return
    const request = ++this.targetRequest
    this.targetsLoading = true
    this.trayMessage = ''
    try {
      const targets = await InboxService.targets(this.getUIContext().getHostContext()!)
      if (request === this.targetRequest) this.targetSections = refileSections(targets)
    } catch (e) {
      if (request === this.targetRequest) { this.targetSections = []; this.trayMessage = coreErrorMessage(e as CoreBridgeError) }
    } finally {
      if (request === this.targetRequest) this.targetsLoading = false
    }
  }

  confirmDelete() {
    if (!this.selected || this.trayBusy) return
    this.getUIContext().showAlertDialog({ title: '删除这条记录？', message: `“${this.selected.heading}”及其子记录将从文件中删除。`,
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除', action: (): void => { this.perform('delete') } } })
  }

  async perform(action: InboxAction, target?: CoreRefileTarget) {
    if (!this.selected || this.trayBusy || this.trayHeight <= 0) return
    const selected = this.selected
    this.trayBusy = true
    this.trayMessage = ''
    ++this.targetRequest
    this.targetsLoading = false
    try {
      await InboxService.perform(this.getUIContext().getHostContext()!, selected, action, target)
      this.trayBusy = false
      this.closeTray()
      await this.loadRecords()
    } catch (e) {
      this.trayMessage = coreErrorMessage(e as CoreBridgeError)
    } finally { this.trayBusy = false }
  }

  capture() {
    if (this.captureOpen || this.drawerOpen) return
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
        this.closeTray()
        this.needsConfiguration = true
        this.records = []
        return
      }
      this.records = result.tasks
      this.measureRows()
      if (this.selected && this.trayHeight > 0) {
        const selected = this.records.find((record: CoreTask) => record.id === this.selected?.id)
        if (!selected) this.closeTray()
        else { this.selected = selected; this.loadTargets() }
      }
    } catch (e) {
      if (request === this.requestId) {
        this.closeTray()
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
      AppShell({ title: '收件箱', titleIcon: $r('app.media.nav_inbox'), synchronized: (): void => { this.loadRecords() }, activeRoute: 'pages/Inbox', drawerOpen: $drawerOpen, pullToSync: true, busy: this.trayBusy }) {
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
                    InboxListItem({ record, selected: this.selected?.id === record.id,
                      open: (): void => { this.selectRecord(record) } })
                  }.width('100%').padding({ left: 12, right: 12 })
                    .onAreaChange((oldArea: Area, newArea: Area): void => {
                      this.rowHeights.set(record.id, parseFloat(newArea.height.toString()))
                      this.measureRows()
                      if (this.selected?.id === record.id) this.revealSelected()
                    })
                }
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
              ListItem() { Column().height(this.selected ? 16 : 104) }
            }.width('100%').layoutWeight(1)
              .onAreaChange((oldArea: Area, newArea: Area): void => {
                this.listHeight = parseFloat(newArea.height.toString()); this.revealSelected()
              })
              .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
              .edgeEffect(EdgeEffect.None)
          }
          if (this.selected && !this.drawerOpen) {
            InboxTargetTray({ sections: this.targetSections, selectionKey: this.selected ? JSON.stringify(this.selected.fullPath) : '', loading: this.targetsLoading,
              busy: this.trayBusy || this.trayHeight === 0, message: this.trayMessage,
              choose: (target: CoreRefileTarget): void => { this.perform('move', target) },
              memo: (): void => { this.perform('memo') }, remove: (): void => { this.confirmDelete() },
              edit: (): void => {
                if (!this.selected || this.trayBusy) return
                const task = this.selected
                this.closeTray()
                this.getUIContext().getRouter().pushUrl({ url: 'pages/TaskEdit', params: { task } })
              },
              retry: (): void => { this.loadRecords() },
              expand: (): void => { this.resizeTray(true) },
              collapse: (): void => { if (this.expandedTray) this.resizeTray(false); else this.closeTray() } })
              .height(this.trayHeight).width('100%').flexShrink(0).clip(true)
          }
        }.width('100%').height('100%').onAreaChange((oldArea: Area, newArea: Area): void => {
          this.contentHeight = Number(newArea.height)
        })
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
