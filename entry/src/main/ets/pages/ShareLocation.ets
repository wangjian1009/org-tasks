import { common } from '@kit.AbilityKit'
import { CoreAddressLink, CoreTask, NativeCoreService } from '../services/NativeCoreService'
import { AppConfig, DEFAULT_CONFIG, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
import { FileTargetService } from '../services/FileTargetService'
import { ShareLocationRequest, SharedLocation, parseSharedLocation, resolveAmapShortUrl } from '../services/SharedLocationService'
import { UiColor } from '../ui/Theme'
import { shareLocationTaskQuery } from '../services/TaskViewQueries'
import { ListSectionHeader } from '../components/Controls'

@Entry
@Component
struct ShareLocation {
  @StorageLink('shareLocationRequest') @Watch('requestChanged') request: ShareLocationRequest = { title: '', url: '' }
  @State location: SharedLocation | undefined = undefined
  @State config: AppConfig = DEFAULT_CONFIG
  @State loadingTasks: boolean = false
  @State created: boolean = false
  @State updatedTask: CoreTask | undefined = undefined
  @State tasks: CoreTask[] = []
  @State selectedTask: CoreTask | undefined = undefined
  @State selectedUri: string = ''
  @State loading: boolean = true
  @State saving: boolean = false
  @State message: string = ''
  @State taskMessage: string = ''
  private loadRequest: number = 0
  private taskRepositories: Map<string, RepoConfig> = new Map<string, RepoConfig>()

  aboutToAppear() {
    this.load()
  }

  requestChanged() {
    this.created = false
    this.updatedTask = undefined
    this.message = ''
    this.load()
  }

  aboutToDisappear() { this.loadRequest++ }

  async load() {
    const request = ++this.loadRequest
    const shared = this.request
    this.loading = true
    this.loadingTasks = false
    this.taskMessage = ''
    this.tasks = []
    this.selectedTask = undefined
    this.selectedUri = ''
    this.taskRepositories.clear()
    try {
      let value = parseSharedLocation(shared)
      if (value.kind === 'unknown' && value.source === 'amap') value = await resolveAmapShortUrl(value)
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!, false)
      if (request !== this.loadRequest) return
      this.location = value
      this.config = config
      if (value.kind !== 'unknown') this.loadTasks(config, request)
    } catch (e) {
      if (request === this.loadRequest) this.message = '无法读取分享内容，请返回地图重新分享'
    } finally { if (request === this.loadRequest) this.loading = false }
  }

  async close(): Promise<void> {
    try { await (this.getUIContext().getHostContext()! as common.UIAbilityContext).terminateSelf() }
    catch (error) { this.message = '关闭分享窗口失败，请重试' }
  }

  sourceName(): string {
    if (this.location?.source === 'amap') return '来自高德地图'
    if (this.location?.source === 'petal') return '来自花瓣地图'
    return '来自分享内容'
  }

  locationText(): string {
    if (!this.location) return ''
    if (this.location.address) return this.location.address
    if (this.location.latitude) return `坐标 ${this.location.latitude}, ${this.location.longitude}`
    return this.location.rawUrl || '未识别地址'
  }

  async loadTasks(config: AppConfig, request: number) {
    this.loadingTasks = true
    try {
      const repositories: Map<string, RepoConfig> = new Map<string, RepoConfig>()
      const results: CoreTask[] = []
      const memoTarget = await FileTargetService.resolve(config, 'memo')
      for (const repository of config.repos) {
        if (request !== this.loadRequest) return
        const query = shareLocationTaskQuery(memoTarget?.repository.id === repository.id ? memoTarget.path : '')
        const result = await NativeCoreService.queryTasks([repository], query, config.todoDefaults)
        for (const task of result.tasks) { results.push(task); repositories.set(task.id, repository) }
      }
      if (request !== this.loadRequest) return
      this.taskRepositories = repositories
      this.tasks = results
    } catch (e) { if (request === this.loadRequest) this.taskMessage = '读取任务失败，请重新分享后重试' }
    finally { if (request === this.loadRequest) this.loadingTasks = false }
  }

  async createTask() {
    if (this.saving || !this.location) return
    this.saving = true; this.message = ''
    try {
      if (!this.created) {
        const target = await FileTargetService.resolve(this.config, 'inbox')
        if (!target) throw new Error('收件箱文件未选择或已失效，请先在设置中选择')
        const label = this.location.label || this.location.address || '分享地点'
        const body = `[[${this.location.uri}][${label}]]`
        await target.repo.createTask(target.path, {
          heading: `到${this.request.title || label}`, body, scheduled: '', deadline: '', tags: [], priority: ''
        }, target.repository.webdavEnabled, true)
        this.created = true
      }
      const context = this.getUIContext().getHostContext()! as common.UIAbilityContext
      await context.startAbility({ bundleName: context.applicationInfo.name, abilityName: 'EntryAbility',
        parameters: { page: 'inbox' } })
      await this.close()
    } catch (e) { this.message = this.created ? '任务已创建，打开收件箱失败，请点击“打开收件箱”重试' : (e as Error).message || '创建任务失败' }
    finally { this.saving = false }
  }

  async updateTask() {
    if (this.saving || !this.selectedTask || !this.location || this.location.kind === 'unknown') return
    const task = this.selectedTask!
    const oldUri = this.selectedUri
    const uri = this.location.uri
    const repository = this.taskRepositories.get(task.id)
    if (!repository) { this.message = '任务所属仓库不可用'; return }
    this.saving = true; this.message = ''
    try {
      if (!this.updatedTask) {
        const repo = await NativeCoreService.repository([repository], repository, this.config.todoDefaults)
        this.updatedTask = await repo.updateTaskLocation(task.filePath, task.heading, oldUri, uri, repository.webdavEnabled)
      }
      const context = this.getUIContext().getHostContext()! as common.UIAbilityContext
      await context.startAbility({ bundleName: context.applicationInfo.name, abilityName: 'EntryAbility',
        parameters: { page: 'taskEdit', task: JSON.stringify(this.updatedTask!) } })
      await this.close()
    } catch (e) { this.message = this.updatedTask ? '地址已更新，打开任务编辑失败，请重试' : (e as Error).message || '更新地址失败' }
    finally { this.saving = false }
  }

  @Builder
  locationCard() {
    if (this.location) {
      Column({ space: 6 }) {
        Row({ space: 12 }) {
          Image(this.location.source === 'amap' ? $r('app.media.map_app_amap') : $r('app.media.map_app_petal'))
            .width(36).height(36).borderRadius(8)
          Column({ space: 4 }) {
            Text(this.location.label || '分享地点').fontSize(19).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
            Text(this.locationText()).fontSize(14).fontColor(UiColor.secondary).maxLines(2)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }
        Text(this.location.kind === 'unknown' ? '无法确认地址' : this.location.kind === 'coordinates' ? '坐标已识别' : '地址已识别')
          .fontSize(13).fontColor(this.location.kind === 'unknown' ? UiColor.error : UiColor.primary).width('100%')
      }.width('100%').padding(16).backgroundColor(UiColor.field).borderRadius(16)
    }
  }

  @Builder
  updateView() {
    Column({ space: 12 }) {
      ListSectionHeader({ title: '更新地址' })
      ForEach(this.tasks, (task: CoreTask) => {
        Column({ space: 8 }) {
          Column({ space: 3 }) {
            Text(task.heading).fontSize(16).fontColor(UiColor.text).maxLines(1).width('100%')
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(task.filePath).fontSize(13).fontColor(UiColor.secondary).width('100%')
          }.width('100%').alignItems(HorizontalAlign.Start)
          ForEach(task.addressLinks, (link: CoreAddressLink) => {
            Row({ space: 8 }) {
              Text(link.label || link.uri).fontSize(14).fontColor(UiColor.primary).maxLines(1).layoutWeight(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.selectedUri === link.uri && this.selectedTask?.id === task.id ? '✓' : '')
                .fontSize(20).fontColor(UiColor.primary)
            }.width('100%').padding({ right: 8, top: 6, bottom: 6 }).constraintSize({ minHeight: 36 })
              .backgroundColor(this.selectedUri === link.uri && this.selectedTask?.id === task.id ? '#3B5550' : Color.Transparent)
              .borderRadius(8).enabled(!this.saving && !this.updatedTask)
              .onClick(() => { this.selectedTask = task; this.selectedUri = link.uri })
          })
        }.width('100%').padding(16).backgroundColor(UiColor.field).borderRadius(12)
      })
      if (!this.loadingTasks && this.selectedTask) {
        Button(this.saving ? '保存中…' : this.updatedTask ? '打开任务编辑' : '更新选中的地址').width('100%').height(52).backgroundColor(UiColor.primary)
          .fontColor(UiColor.onPrimary)
          .enabled(!this.saving).onClick(() => { this.updateTask() })
      }
    }.width('100%')
  }

  build() {
    Column() {
      Row() {
        Text('取消').fontSize(16).fontColor(UiColor.secondary).onClick(() => { this.close() })
        Text('分享地点')
          .fontSize(20).fontWeight(FontWeight.Medium).fontColor(UiColor.text).layoutWeight(1).textAlign(TextAlign.Center)
        Blank().width(42)
      }.width('100%').height(64).padding({ left: 20, right: 20 })
      Divider().color(UiColor.outline)
      Scroll() {
        Column({ space: 16 }) {
          if (this.loading) {
            Text('正在读取分享内容…').fontSize(18).fontColor(UiColor.text).padding(24)
          } else {
            Text(this.sourceName()).fontSize(14).fontColor(UiColor.primary).width('100%').padding({ top: 18 })
            this.locationCard()
            if (this.location?.kind === 'unknown') {
              Text('分享内容无法确认地址，可保存原始链接或返回地图重新分享。').fontSize(14).fontColor(UiColor.warning).width('100%')
              Button(this.saving ? '保存中…' : this.created ? '打开收件箱' : '创建任务并保存原始链接').width('100%').height(50)
                .backgroundColor(UiColor.field).fontColor(UiColor.text).enabled(!this.saving).onClick(() => { this.createTask() })
            } else {
              Button(this.saving ? '保存中…' : this.created ? '打开收件箱' : '创建任务').width('100%').height(52).backgroundColor(UiColor.primary)
                .fontColor(UiColor.onPrimary).enabled(!this.saving).onClick(() => { this.createTask() })
              if (!this.loadingTasks && this.tasks.length > 0) {
                this.updateView()
              }
            }
          }
          if (this.message) {
            Text(this.message).fontSize(14).fontColor(UiColor.error).width('100%')
          }
          if (this.taskMessage) {
            Text(this.taskMessage).fontSize(14).fontColor(UiColor.error).width('100%')
          }
        }.width('100%').padding(20)
      }.layoutWeight(1).align(Alignment.TopStart)
    }.width('100%').height('100%').backgroundColor(UiColor.surface)
  }
}
