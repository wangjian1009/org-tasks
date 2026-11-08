import { common } from '@kit.AbilityKit'
import { CoreAddressLink, CoreTask, NativeCoreService } from '../services/NativeCoreService'
import { AppConfig, DEFAULT_CONFIG, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
import { FileTargetService } from '../services/FileTargetService'
import { ShareLocationRequest, SharedLocation, parseSharedLocation, resolveAmapShortUrl } from '../services/SharedLocationService'
import { UiColor } from '../ui/Theme'
import { TaskListItem } from '../components/TaskListItem'
import { inboxRecordQuery, shareLocationTaskQuery } from '../services/TaskViewQueries'

@Entry
@Component
struct ShareLocation {
  @StorageLink('shareLocationRequest') @Watch('requestChanged') request: ShareLocationRequest = { title: '', url: '' }
  @State location: SharedLocation | undefined = undefined
  @State config: AppConfig = DEFAULT_CONFIG
  @State inlineUpdate: boolean = false
  @State loadingTasks: boolean = false
  @State created: boolean = false
  @State createdTask: CoreTask | undefined = undefined
  @State tasks: CoreTask[] = []
  @State selectedTask: CoreTask | undefined = undefined
  @State selectedUri: string = ''
  @State loading: boolean = true
  @State saving: boolean = false
  @State message: string = ''
  private taskRepositories: Map<string, RepoConfig> = new Map<string, RepoConfig>()

  aboutToAppear() {
    this.load()
  }

  requestChanged() {
    this.inlineUpdate = false
    this.created = false
    this.createdTask = undefined
    this.message = ''
    this.load()
  }

  async load() {
    this.loading = true
    try {
      let value = parseSharedLocation(this.request)
      if (value.kind === 'unknown' && value.source === 'amap') value = await resolveAmapShortUrl(value)
      this.location = value
      this.config = await AppConfigService.load(this.getUIContext().getHostContext()!, false)
    } catch (e) {
      this.message = '无法读取分享内容，请返回地图重新分享'
    } finally { this.loading = false }
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

  async openUpdate() {
    if (!this.location || this.location.kind === 'unknown' || this.saving) return
    if (this.inlineUpdate) {
      this.inlineUpdate = false
      return
    }
    this.inlineUpdate = true
    if (this.loadingTasks) return
    this.loadingTasks = true
    this.message = ''
    this.tasks = []
    this.selectedTask = undefined
    this.selectedUri = ''
    try {
      this.taskRepositories.clear()
      const results: CoreTask[] = []
      const memoTarget = await FileTargetService.resolve(this.config, 'memo')
      for (const repository of this.config.repos) {
        const query = shareLocationTaskQuery(memoTarget?.repository.id === repository.id ? memoTarget.path : '')
        const result = await NativeCoreService.queryTasks([repository], query, this.config.todoDefaults)
        for (const task of result.tasks) { results.push(task); this.taskRepositories.set(task.id, repository) }
      }
      this.tasks = results
    } catch (e) { this.message = '读取任务失败，请收起后重试' }
    finally { this.loadingTasks = false }
  }

  async createTask() {
    if (this.saving || this.created || !this.location) return
    this.saving = true; this.message = ''
    try {
      const target = await FileTargetService.resolve(this.config, 'inbox')
      if (!target) throw new Error('收件箱文件未选择或已失效，请先在设置中选择')
      const label = this.location.label || this.location.address || '分享地点'
      const body = `[[${this.location.uri}][${label}]]`
      await target.repo.createTask(target.path, {
        heading: `到${this.request.title || label}`, body, scheduled: '', deadline: '', tags: [], priority: ''
      }, target.repository.webdavEnabled, true)
      this.created = true
      this.inlineUpdate = false
      this.message = '任务已创建'
      const result = await NativeCoreService.queryTasks([target.repository], inboxRecordQuery(target.path), this.config.todoDefaults)
      this.createdTask = result.tasks[0]
      if (!this.createdTask) this.message = '任务已创建，但暂时无法读取，请到收件箱查看'
    } catch (e) { this.message = this.created ? '任务已创建，但暂时无法读取，请到收件箱查看' : (e as Error).message || '创建任务失败' }
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
      const repo = await NativeCoreService.repository([repository], repository, this.config.todoDefaults)
      await repo.updateTaskLocation(task.filePath, task.heading, oldUri, uri, repository.webdavEnabled)
      this.message = '地址已更新'
    } catch (e) { this.message = (e as Error).message || '更新地址失败' }
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
      Divider().color(UiColor.outline)
      Text('选择要更新的地址').fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiColor.text).width('100%')
      if (this.loadingTasks) {
        Text('正在读取任务…').fontSize(14).fontColor(UiColor.secondary).width('100%')
      } else if (this.tasks.length === 0) {
        Text('暂无包含地址链接的未完成任务或备忘').fontSize(14).fontColor(UiColor.secondary).width('100%')
      }
      ForEach(this.tasks, (task: CoreTask) => {
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(task.heading).fontSize(16).fontColor(UiColor.text).maxLines(1)
            Text(task.filePath).fontSize(13).fontColor(UiColor.secondary)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').padding({ left: 14, right: 14, top: 10, bottom: 6 })
        ForEach(task.addressLinks, (link: CoreAddressLink) => {
          Row({ space: 8 }) {
            Text(link.label || link.uri).fontSize(14).fontColor(UiColor.primary).maxLines(1).layoutWeight(1)
            Text(this.selectedUri === link.uri && this.selectedTask?.id === task.id ? '✓' : '')
              .fontSize(20).fontColor(UiColor.primary)
          }.width('100%').padding({ left: 28, right: 14, top: 8, bottom: 8 })
            .backgroundColor(this.selectedUri === link.uri && this.selectedTask?.id === task.id ? '#3B5550' : UiColor.field)
            .borderRadius(8).onClick(() => { this.selectedTask = task; this.selectedUri = link.uri })
        })
      })
      Button(this.saving ? '更新中…' : '更新选中的地址').width('100%').height(52).backgroundColor(UiColor.primary)
        .fontColor(UiColor.onPrimary)
        .enabled(this.selectedTask !== undefined && !this.saving).onClick(() => { this.updateTask() })
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
          } else if (this.created) {
            Text('任务已创建到收件箱').fontSize(18).fontColor(UiColor.primary).width('100%')
            if (this.createdTask) {
              TaskListItem({ task: this.createdTask!, initiallyExpanded: true, open: (): void => {
                this.getUIContext().getRouter().pushUrl({ url: 'pages/TaskEdit', params: { task: this.createdTask } })
              } })
            }
            Button('完成').onClick(() => { this.close() })
          } else if (this.message === '地址已更新') {
            Text(this.message).fontSize(24).fontColor(UiColor.text).padding({ top: 40, bottom: 20 })
            Text('任务中的地址链接已替换')
              .fontSize(16).fontColor(UiColor.secondary)
            Button('完成').onClick(() => { this.close() }).margin({ top: 28 })
          } else {
            Text(this.sourceName()).fontSize(14).fontColor(UiColor.primary).width('100%').padding({ top: 18 })
            this.locationCard()
            if (this.location?.kind === 'unknown') {
              Text('分享内容无法确认地址，可保存原始链接或返回地图重新分享。').fontSize(14).fontColor(UiColor.warning).width('100%')
              Button(this.saving ? '创建中…' : '创建任务并保存原始链接').width('100%').height(50)
                .backgroundColor(UiColor.field).fontColor(UiColor.text).enabled(!this.saving).onClick(() => { this.createTask() })
            } else {
              Button(this.saving ? '创建中…' : '创建任务').width('100%').height(52).backgroundColor(UiColor.primary)
                .fontColor(UiColor.onPrimary).enabled(!this.saving).onClick(() => { this.createTask() })
              Text(this.inlineUpdate ? '收起任务地址选择' : '更新已有任务地址').fontSize(16).fontColor(UiColor.primary).width('100%').textAlign(TextAlign.Center)
                .padding({ top: 12, bottom: 12 }).onClick(() => { this.openUpdate() })
              if (this.inlineUpdate) {
                this.updateView()
              }
            }
          }
          if (this.message && this.message !== '任务已创建' && this.message !== '地址已更新') {
            Text(this.message).fontSize(14).fontColor(UiColor.error).width('100%')
          }
        }.width('100%').padding(20)
      }.layoutWeight(1).align(Alignment.TopStart)
    }.width('100%').height('100%').backgroundColor(UiColor.surface)
  }
}
