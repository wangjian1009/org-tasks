import { taskRenderKey } from '../ui/TaskPresentation'
import { UiColor } from '../ui/Theme'
import { KeyboardAvoidMode } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/Controls'
import { TaskListItem } from '../components/TaskListItem'
import { AppConfigService } from '../services/AppConfigService'
import { CaptureService } from '../services/CaptureService'
import { FileTargetService } from '../services/FileTargetService'
import { CoreBridgeError, CoreTask, coreErrorMessage } from '../services/NativeCoreService'

@Entry
@Component
struct Inbox {
  @State records: CoreTask[] = []
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State needsConfiguration: boolean = false
  @State captureOpen: boolean = false
  @State captureTitle: string = ''
  @State captureSaving: boolean = false
  @State captureMessage: string = ''
  private requestId: number = 0
  private captureFocusTimer: number = -1
  private keyboardAvoidMode: KeyboardAvoidMode = KeyboardAvoidMode.OFFSET

  onPageShow() { this.loadRecords() }
  aboutToDisappear() {
    clearTimeout(this.captureFocusTimer)
    if (this.captureOpen) this.getUIContext().setKeyboardAvoidMode(this.keyboardAvoidMode)
  }

  onBackPress(): boolean {
    if (this.captureOpen) { this.closeCapture(); return true }
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
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

  async loadRecords() {
    const request = ++this.requestId
    this.loading = this.records.length === 0
    this.message = ''
    this.needsConfiguration = false
    try {
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      const result = await FileTargetService.query(config, 'inbox')
      if (request !== this.requestId) return
      if (!result) {
        this.needsConfiguration = true
        this.records = []
        return
      }
      this.records = result.tasks
    } catch (e) {
      if (request === this.requestId) {
        this.records = []
        this.message = `读取收件箱失败：${coreErrorMessage(e as CoreBridgeError)}`
      }
    } finally {
      if (request === this.requestId) this.loading = false
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      AppShell({ title: '收件箱', titleIcon: $r('app.media.nav_inbox'), synchronized: (): void => { this.loadRecords() }, activeRoute: 'pages/Inbox', drawerOpen: $drawerOpen, pullToSync: true }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在读取收件箱', busy: true })
          } else if (this.needsConfiguration) {
            EmptyState({ title: '收件箱文件未选择或已失效', detail: '请在设置的“笔记与笔记本”中重新选择仓库和文件。',
              actionLabel: '前往设置', action: (): void => {
                this.getUIContext().getRouter().pushUrl({ url: 'pages/Settings', params: { section: '笔记与笔记本' } })
              } })
          } else if (this.message) {
            EmptyState({ title: '收件箱读取失败', detail: this.message,
              actionLabel: '重试', action: (): void => { this.loadRecords() } })
          } else {
            if (this.records.length === 0) {
              EmptyState({ title: '收件箱没有记录', detail: '收件箱中的所有标题记录都会显示在这里，包含没有任务状态和已完成的记录。' })
            } else {
              List() {
                ForEach(this.records, (task: CoreTask) => {
                  ListItem() {
                    TaskListItem({ task, enableCompletionState: false, open: (): void => {
                      this.getUIContext().getRouter().pushUrl({ url: 'pages/InboxPlan', params: { task } })
                    } })
                  }
                }, (task: CoreTask) => taskRenderKey(task))
              }.width('100%').layoutWeight(1).padding({ bottom: 104 })
                .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
                .edgeEffect(EdgeEffect.None)
            }
          }
        }.width('100%').height('100%')
      }
      if (!this.drawerOpen && !this.captureOpen) {
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
