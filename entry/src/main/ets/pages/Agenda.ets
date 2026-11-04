import { router } from '@kit.ArkUI'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, coreErrorMessage, CoreTask, NativeCoreService } from '../services/NativeCoreService'
import { AppShell } from '../components/AppShell'
import { EmptyState, TaskRow } from '../components/Controls'
import { dateLabel, localDate, UiColor } from '../ui/Theme'

interface AgendaGroup {
  key: string
  title: string
  tasks: CoreTask[]
}

@Entry
@Component
struct Agenda {
  @State groups: AgendaGroup[] = []
  @State filter: string = '全部'
  @State message: string = ''
  @State loading: boolean = true
  @State drawerOpen: boolean = false
  @State config: AppConfig = DEFAULT_CONFIG
  private requestId: number = 0

  onPageShow() { this.loadTasks() }
  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  async loadTasks() {
    const request = ++this.requestId
    this.loading = true
    this.message = ''
    try {
      const config = await AppConfigService.load(getContext(this))
      const condition = this.filter === '计划' ? 's.ge.-100y' : this.filter === '截止' ? 'd.ge.-100y' : '(s.ge.-100y or d.ge.-100y)'
      const response = await NativeCoreService.searchWorkspace(config.repos, `.it.done ${condition}`, config.todoDefaults)
      if (request !== this.requestId) return
      this.config = config
      const tasks = response.tasks.slice().sort((a: CoreTask, b: CoreTask) => this.taskDate(a).localeCompare(this.taskDate(b)))
      const groups: AgendaGroup[] = []
      const today = localDate(new Date())
      for (const task of tasks) {
        const date = this.taskDate(task)
        const key = date < today ? 'overdue' : date
        let group = groups.find((item: AgendaGroup) => item.key === key)
        if (!group) {
          group = { key, title: key === 'overdue' ? '过期' : date === today ? `今天 · ${dateLabel(date)}` : dateLabel(date), tasks: [] }
          groups.push(group)
        }
        group.tasks.push(task)
      }
      this.groups = groups
    } catch (e) {
      if (request === this.requestId) { this.groups = []; this.message = `读取日程失败：${coreErrorMessage(e as CoreBridgeError)}` }
    } finally {
      if (request === this.requestId) this.loading = false
    }
  }

  taskDate(task: CoreTask): string {
    if (this.filter === '计划') return task.scheduled
    if (this.filter === '截止') return task.deadline
    if (!task.scheduled) return task.deadline
    if (!task.deadline) return task.scheduled
    return task.scheduled < task.deadline ? task.scheduled : task.deadline
  }

  build() {
    Column() {
      AppShell({ title: '日程', synchronized: (): void => { this.loadTasks() }, activeRoute: 'pages/Agenda', drawerOpen: $drawerOpen,
      actionLabel: '搜索笔记', action: (): void => { router.pushUrl({ url: 'pages/Search' }) },
      extraIcon: $r('app.media.ui_sync'), extraLabel: '刷新日程', extraAction: (): void => { this.loadTasks() },
      fabLabel: '新增任务', fabAction: (): void => { router.pushUrl({ url: 'pages/AddTask' }) } }) {
        Column() {
          Row({ space: 8 }) {
            ForEach(['全部', '计划', '截止'], (item: string) => {
              Button(item).height(34).fontSize(13).backgroundColor(this.filter === item ? UiColor.selected : UiColor.surface)
                .fontColor(this.filter === item ? UiColor.onSelected : UiColor.secondary)
                .border({ width: 1, color: UiColor.outline }).onClick(() => { this.filter = item; this.loadTasks() })
            })
          }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
          if (this.loading) {
            EmptyState({ title: '正在读取日程', detail: '正在加载仓库中的计划与截止任务', busy: true })
          } else if (this.message) {
            EmptyState({ title: '日程读取失败', detail: this.message, actionLabel: '重试', action: (): void => { this.loadTasks() } })
          } else if (this.groups.length === 0) {
            EmptyState({ title: '没有待安排的日程', detail: this.config.repos.length === 0 ? '先添加存储库，再查看计划与截止任务。' : '未完成笔记有计划或截止日期时，会按日期显示在这里。',
              actionLabel: this.config.repos.length === 0 ? '添加存储库' : '新增任务',
              action: (): void => { router.pushUrl({ url: this.config.repos.length === 0 ? 'pages/Files' : 'pages/AddTask' }) } })
          } else {
            List() {
              ForEach(this.groups, (group: AgendaGroup) => {
                ListItemGroup({ header: this.groupHeader(group.title) }) {
                  ForEach(group.tasks, (task: CoreTask) => {
                    ListItem() {
                      TaskRow({ task, open: (): void => { router.pushUrl({ url: 'pages/TaskDetail', params: { task } }) } })
                    }
                  }, (task: CoreTask) => task.id)
                }
              }, (group: AgendaGroup) => group.key)
            }.width('100%').layoutWeight(1).padding({ bottom: 88 }).sticky(StickyStyle.Header)
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }

  @Builder
  groupHeader(title: string) {
    Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiColor.secondary).width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 16 }).backgroundColor(UiColor.container)
      .border({ width: { bottom: 0.5 }, color: UiColor.outline })
  }
}
