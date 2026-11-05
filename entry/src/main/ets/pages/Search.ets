import { router } from '@kit.ArkUI'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, coreErrorMessage, CoreTask, NativeCoreService } from '../services/NativeCoreService'
import { AppShell } from '../components/AppShell'
import { EmptyState, TaskRow } from '../components/Controls'
import { UiColor } from '../ui/Theme'

interface SearchParams { query?: string; name?: string; run?: boolean }

@Entry
@Component
struct TaskSearch {
  @State keyword: string = ''
  @State query: string = ''
  @State advanced: boolean = false
  @State excludeDone: boolean = false
  @State stateFilter: string = '全部'
  @State tasks: CoreTask[] = []
  @State message: string = ''
  @State loading: boolean = false
  @State showingResults: boolean = false
  @State drawerOpen: boolean = false
  @State name: string = ''
  @State committedQuery: string = ''
  private requestId: number = 0

  aboutToAppear() {
    const params = router.getParams() as SearchParams | undefined
    if (params?.query !== undefined) {
      this.query = params.query
      this.advanced = true
      this.name = params.name || ''
      if (params.run) this.search()
    }
  }

  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    if (this.showingResults) { this.showingResults = false; return true }
    return false
  }

  onPageShow() {
    if (this.showingResults && !this.loading) this.search()
  }

  expression(): string {
    if (this.advanced) return this.query.trim()
    // 仅组装已支持的查询参数，所有求值仍交给 core。
    const terms: string[] = []
    if (this.keyword.trim()) terms.push(`"${this.keyword.trim().replace(/"/g, '')}"`)
    if (this.excludeDone) terms.push('.it.done')
    if (this.stateFilter === '待办') terms.push('i.todo')
    if (this.stateFilter === '已完成') terms.push('it.done')
    return terms.join(' ')
  }

  switchMode() {
    if (this.advanced) {
      this.getUIContext().showAlertDialog({ title: '使用简单筛选？', message: '将恢复上次的简单筛选条件；高级查询草稿仍保留在当前页面。',
        primaryButton: { value: '取消', action: () => {} }, secondaryButton: { value: '切换', action: () => { this.advanced = false } } })
      return
    }
    if (!this.query) this.query = this.expression()
    this.advanced = true
    this.message = ''
  }

  async search() {
    const request = ++this.requestId
    const expression = this.expression()
    this.loading = true
    this.message = ''
    this.showingResults = true
    try {
      const config = await AppConfigService.load(getContext(this))
      const response = await NativeCoreService.searchWorkspace(config.repos, expression, config.todoDefaults)
      if (request !== this.requestId) return
      this.tasks = response.tasks
      this.committedQuery = expression
    } catch (e) {
      if (request === this.requestId) { this.tasks = []; this.message = `搜索失败：${coreErrorMessage(e as CoreBridgeError)}` }
    } finally {
      if (request === this.requestId) this.loading = false
    }
  }

  @Builder
  form() {
    Scroll() {
      Column({ space: 16 }) {
        Text(this.advanced ? '查询表达式' : '搜索文字').fontSize(13).fontColor(UiColor.primary).width('100%')
        TextInput({ placeholder: this.advanced ? '例如：.it.done s.le.7d' : '标题、正文或标签', text: this.advanced ? this.query : this.keyword })
          .height(56).borderRadius(6).backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary).fontColor(UiColor.text)
          .enterKeyType(EnterKeyType.Search).onSubmit((): void => { this.search() })
          .onChange((value: string) => { if (this.advanced) this.query = value; else this.keyword = value })
        Button(this.advanced ? '切换到简单筛选' : '切换到高级查询').height(42).fontSize(13)
          .backgroundColor(Color.Transparent).fontColor(UiColor.primary).align(Alignment.End).onClick((): void => { this.switchMode() })
        if (!this.advanced) {
          Row({ space: 12 }) {
            Checkbox({ name: 'excludeDone' }).select(this.excludeDone).selectedColor(UiColor.primary)
              .onChange((value: boolean) => { this.excludeDone = value; if (value && this.stateFilter === '已完成') this.stateFilter = '全部' })
            Text('排除已完成笔记').fontSize(16).fontColor(UiColor.text)
          }.width('100%').height(48)
          Divider().color(UiColor.outline)
          Text('状态').fontSize(14).fontColor(UiColor.secondary).width('100%')
          Row({ space: 8 }) {
            ForEach(['全部', '待办', '已完成'], (state: string) => {
              Button(state).height(36).fontSize(13).backgroundColor(this.stateFilter === state ? UiColor.selected : UiColor.surface)
                .fontColor(this.stateFilter === state ? UiColor.onSelected : UiColor.secondary)
                .onClick(() => { this.stateFilter = state; if (state === '已完成') this.excludeDone = false })
            })
          }.width('100%')
        } else {
          Text('可使用状态、标签、笔记本和日期条件组合查询。').fontSize(14).fontColor(UiColor.secondary).width('100%').lineHeight(22)
          Text('i.todo  ·  t.work  ·  b.inbox  ·  s.le.7d').fontSize(14).fontColor(UiColor.primary).width('100%')
        }
        Button('搜索').width('100%').height(48).backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary)
          .margin({ top: 24 }).onClick((): void => { this.search() })
      }.width('100%').padding(24)
    }.width('100%').height('100%').align(Alignment.TopStart)
  }

  build() {
    Column() {
      AppShell({ title: this.showingResults ? (this.name || '搜索结果') : '搜索', titleIcon: $r('app.media.nav_search'), synchronized: (): void => { if (this.showingResults) this.search() }, activeRoute: 'pages/Search', back: !this.showingResults,
      drawerOpen: $drawerOpen, pullToSync: this.showingResults, actionIcon: this.showingResults ? $r('app.media.ui_edit') : $r('app.media.ui_folder'),
      actionLabel: this.showingResults ? '调整筛选' : '', action: () => { this.showingResults = false } }) {
        Column() {
          if (!this.showingResults) {
            this.form()
          } else if (this.loading) {
            EmptyState({ title: '正在搜索笔记', busy: true })
          } else if (this.message) {
            EmptyState({ title: '搜索失败', detail: this.message, actionLabel: '调整筛选', action: () => { this.showingResults = false } })
          } else {
            Text(`${this.tasks.length} 条笔记${this.committedQuery ? ` · ${this.committedQuery}` : ''}`)
              .fontSize(13).fontColor(UiColor.secondary).width('100%').padding(16).backgroundColor(UiColor.container)
            if (this.tasks.length === 0) {
              EmptyState({ title: '没有匹配的笔记', detail: '试试其他关键词，或调整查询条件。', actionLabel: '调整筛选', action: () => { this.showingResults = false } })
            } else {
              List() {
                ForEach(this.tasks, (task: CoreTask) => {
                  ListItem() { TaskRow({ task, showBody: true, open: (): void => { router.pushUrl({ url: 'pages/TaskDetail', params: { task } }) } }) }
                }, (task: CoreTask) => task.id)
              }.width('100%').layoutWeight(1).padding({ bottom: 16 })
                .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
                .edgeEffect(EdgeEffect.None)
            }
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
