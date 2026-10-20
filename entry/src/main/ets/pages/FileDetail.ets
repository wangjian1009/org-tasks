import { router } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { EmptyState, TaskRow } from '../components/Controls'
import { AppConfigService } from '../services/AppConfigService'
import { NotebookService } from '../services/NotebookService'
import { CoreBridgeError, coreErrorMessage, CoreTask, CoreTodoMetadata } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'

interface NotebookParams { repoId?: string; path?: string }

@Entry
@Component
struct FileDetail {
  @State path: string = ''
  @State repoId: string = ''
  @State content: string = ''
  @State todo: CoreTodoMetadata | undefined = undefined
  @State tasks: CoreTask[] = []
  @State collapsed: string[] = []
  @State tab: string = '笔记'
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State rootDirectory: string = ''

  onPageShow() { this.loadFile() }
  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  async loadFile() {
    this.loading = true
    try {
      const params = router.getParams() as NotebookParams
      this.path = params.path || ''
      this.repoId = params.repoId || ''
      const config = await AppConfigService.load(getContext(this))
      const notebooks = await NotebookService.load(config.repos, config.todoDefaults)
      const file = notebooks.find((item) => item.repoId === this.repoId && item.path === this.path)
      if (!file) { this.message = '该笔记本已不存在，请返回笔记本列表。'; return }
      this.todo = file.todo
      this.tasks = file.tasks
      this.content = file.source
      this.rootDirectory = file.rootDirectory
      this.message = ''
    } catch (e) {
      this.message = `读取笔记本失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally { this.loading = false }
  }

  hasChildren(task: CoreTask): boolean {
    const index = this.tasks.findIndex((item: CoreTask) => item.id === task.id)
    return index >= 0 && index + 1 < this.tasks.length && this.tasks[index + 1].level > task.level
  }

  visibleTasks(): CoreTask[] {
    const visible: CoreTask[] = []
    let hiddenLevel = 0
    for (const task of this.tasks) {
      if (hiddenLevel > 0 && task.level > hiddenLevel) continue
      hiddenLevel = 0
      visible.push(task)
      if (this.collapsed.includes(task.id)) hiddenLevel = task.level
    }
    return visible
  }

  toggle(task: CoreTask) {
    this.collapsed = this.collapsed.includes(task.id) ? this.collapsed.filter((id: string) => id !== task.id) : [...this.collapsed, task.id]
  }

  openTask(task: CoreTask) {
    const index = this.tasks.findIndex((item: CoreTask) => item.id === task.id)
    const parents: CoreTask[] = []
    let level = task.level
    for (let i = index - 1; i >= 0; i--) {
      if (this.tasks[i].level < level) { parents.unshift(this.tasks[i]); level = this.tasks[i].level }
    }
    router.pushUrl({ url: 'pages/TaskDetail', params: { task, parents: parents.map((item: CoreTask) => item.heading) } })
  }

  build() {
    Column() {
      AppShell({ title: this.path || '笔记本', back: true, drawerOpen: $drawerOpen,
      actionIcon: $r('app.media.ui_expand'), actionLabel: this.collapsed.length > 0 ? '展开全部' : '收起全部',
      action: () => { this.collapsed = this.collapsed.length > 0 ? [] : this.tasks.filter((task: CoreTask) => this.hasChildren(task)).map((task: CoreTask) => task.id) },
      extraIcon: $r('app.media.ui_search'), extraLabel: '搜索笔记', extraAction: (): void => { router.pushUrl({ url: 'pages/Search' }) },
      fabLabel: '新增任务', fabAction: (): void => { router.pushUrl({ url: 'pages/AddTask', params: { rootDirectory: this.rootDirectory } }) } }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在打开笔记本', busy: true })
          } else if (this.message) {
            EmptyState({ title: '无法打开笔记本', detail: this.message, actionLabel: '重试', action: (): void => { this.loadFile() } })
          } else {
            Row({ space: 8 }) {
              ForEach(['笔记', '原文'], (tab: string) => {
                Button(tab).height(34).fontSize(13).fontColor(this.tab === tab ? UiColor.onSelected : UiColor.secondary)
                  .backgroundColor(this.tab === tab ? UiColor.selected : Color.Transparent)
                  .onClick(() => { this.tab = tab })
              })
              Blank()
              Text(`${this.tasks.length} 条笔记`).fontSize(12).fontColor(UiColor.secondary)
            }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
            if (this.todo) {
              Text(`TODO 状态来自${this.todo.source === 'inBuffer' ? '本文件' : '全局默认'}：${this.todo.pendingKeywords.concat(this.todo.doneKeywords).join(' → ') || '未启用'}`)
                .width('100%').padding({ left: 16, right: 16, bottom: 12 }).fontSize(12).fontColor(UiColor.secondary)
            }
            if (this.tab === '原文') {
              Scroll() {
                Text(this.content || '空白 org 文件').width('100%').fontSize(14).fontFamily('monospace')
                  .fontColor(UiColor.text).copyOption(CopyOptions.LocalDevice).padding(16)
              }.width('100%').layoutWeight(1).align(Alignment.TopStart)
            } else if (this.tasks.length === 0) {
              EmptyState({ title: '这个笔记本还是空的', detail: '切换到原文查看文件，或新增任务写入收集箱。' })
            } else {
              List() {
                ForEach(this.visibleTasks(), (task: CoreTask) => {
                  ListItem() {
                    TaskRow({ task, showSource: false, showBody: true, indent: Math.min(Math.max(task.level - 1, 0), 8) * 20,
                      canFold: this.hasChildren(task), folded: this.collapsed.includes(task.id),
                      fold: (): void => { this.toggle(task) }, open: (): void => { this.openTask(task) } })
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
