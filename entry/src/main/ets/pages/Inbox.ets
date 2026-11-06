import { taskRenderKey } from '../ui/TaskPresentation'
import { UiColor } from '../ui/Theme'
import { common } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { EmptyState, TaskRow } from '../components/Controls'
import { AppConfigService } from '../services/AppConfigService'
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
  @State openingCapture: boolean = false
  private requestId: number = 0

  onPageShow() { this.loadRecords() }

  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  async capture() {
    if (this.openingCapture || this.drawerOpen) return
    this.openingCapture = true
    try {
      const context = getContext(this) as common.UIAbilityContext
      await context.startAbilityForResult({ bundleName: context.abilityInfo.bundleName,
        abilityName: 'CaptureAbility', parameters: { captureMode: 'text' } })
      await this.loadRecords()
    } catch (e) {
      this.getUIContext().showAlertDialog({ title: '无法打开记一条', message: coreErrorMessage(e as CoreBridgeError),
        confirm: { value: '知道了', action: () => {} } })
    } finally { this.openingCapture = false }
  }

  async loadRecords() {
    const request = ++this.requestId
    this.loading = this.records.length === 0
    this.message = ''
    this.needsConfiguration = false
    try {
      const config = await AppConfigService.load(getContext(this))
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
                router.pushUrl({ url: 'pages/Settings', params: { section: '笔记与笔记本' } })
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
                    TaskRow({ task, showFilePath: false, showBody: true, open: (): void => {
                      router.pushUrl({ url: 'pages/InboxPlan', params: { task } })
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
      if (!this.drawerOpen) {
        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.ui_add_primary')).width(28).height(28)
        }.id('inbox_capture').width(56).height(56).backgroundColor(UiColor.primary)
          .shadow({ radius: 12, color: '#33000000', offsetY: 4 }).margin({ bottom: 24 })
          .accessibilityText('记一条').enabled(!this.openingCapture)
          .onClick((): void => { this.capture() })
      }
    }.width('100%').height('100%')
  }
}
