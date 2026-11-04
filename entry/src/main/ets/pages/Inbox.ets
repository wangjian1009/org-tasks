import { router } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { EmptyState, TaskRow } from '../components/Controls'
import { AppConfigService } from '../services/AppConfigService'
import { inboxRecordQuery } from '../services/TaskViewQueries'
import { CoreBridgeError, CoreTask, NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'

@Entry
@Component
struct Inbox {
  @State records: CoreTask[] = []
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State needsConfiguration: boolean = false
  private requestId: number = 0

  onPageShow() { this.loadRecords() }

  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  async loadRecords() {
    const request = ++this.requestId
    this.loading = true
    this.message = ''
    this.needsConfiguration = false
    try {
      const config = await AppConfigService.load(getContext(this))
      if (!config.inboxFile) {
        this.needsConfiguration = true
        this.records = []
        return
      }
      const result = await NativeCoreService.queryTasks(config.repos, inboxRecordQuery(config.inboxFile), config.todoDefaults)
      if (request !== this.requestId) return
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
    Column() {
      AppShell({ title: '收件箱', titleIcon: $r('app.media.nav_inbox'), synchronized: (): void => { this.loadRecords() }, activeRoute: 'pages/Inbox', drawerOpen: $drawerOpen,
        actionIcon: $r('app.media.ui_sync'), actionLabel: '刷新收件箱', action: (): void => { this.loadRecords() },
        fabLabel: '新增记录', fabAction: (): void => { router.pushUrl({ url: 'pages/AddTask' }) } }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在读取收件箱', busy: true })
          } else if (this.needsConfiguration) {
            EmptyState({ title: '尚未配置收件箱', detail: '请在设置的“笔记与笔记本”中配置收件箱文件。',
              actionLabel: '前往设置', action: (): void => {
                router.pushUrl({ url: 'pages/Settings', params: { section: '笔记与笔记本' } })
              } })
          } else if (this.message) {
            EmptyState({ title: '收件箱读取失败', detail: this.message,
              actionLabel: '重试', action: (): void => { this.loadRecords() } })
          } else {
            Text(`${this.records.length} 条记录`).fontSize(13).fontColor(UiColor.secondary)
              .width('100%').padding(16).backgroundColor(UiColor.container)
            if (this.records.length === 0) {
              EmptyState({ title: '收件箱没有记录', detail: '收件箱中的所有标题记录都会显示在这里，包含没有任务状态和已完成的记录。' })
            } else {
              List() {
                ForEach(this.records, (task: CoreTask) => {
                  ListItem() {
                    TaskRow({ task, showBody: true, open: (): void => {
                      router.pushUrl({ url: 'pages/TaskDetail', params: { task } })
                    } })
                  }
                }, (task: CoreTask) => task.id)
              }.width('100%').layoutWeight(1).padding({ bottom: 88 })
            }
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
