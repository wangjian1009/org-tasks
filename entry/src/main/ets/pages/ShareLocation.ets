import { localizedText } from '../ui/LocalizedText'
import { isSystemRepository } from '../models/SystemRepository'
import { common } from '@kit.AbilityKit'
import { CoreAddressLink, CoreOrgFileRef, CoreQuery, CoreTask, NativeCoreService, taskResult } from '../services/NativeCoreService'
import { AppConfig, DEFAULT_CONFIG, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
import { FileTargetService } from '../services/FileTargetService'
import { ShareLocationRequest, SharedLocation, parseSharedLocation, resolveAmapShortUrl } from '../services/SharedLocationService'
import { UiColor } from '../ui/Theme'
import { compareRecords } from '../ui/QueryOrderPresentation'
import { shareLocationTaskQueries } from '../services/TaskViewQueries'
import { DeviceBadgeService } from '../services/DeviceBadgeService'
import { ListSectionHeader } from '../components/controls/ListSectionHeader'

@Entry
@Component
struct ShareLocation {
  @StorageLink('shareLocationRequest') @Watch('requestChanged') request: ShareLocationRequest = { title: '', url: '' }
  @State location: SharedLocation | undefined = undefined
  @State config: AppConfig = DEFAULT_CONFIG
  @State loadingTasks: boolean = false
  @State created: boolean = false
  @State updated: boolean = false
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
    this.updated = false
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
      if (request === this.loadRequest) this.message = localizedText($r('app.string.text_cannot_read_shared_content_please_return_map'))
    } finally { if (request === this.loadRequest) this.loading = false }
  }

  async close(): Promise<void> {
    try { await (this.getUIContext().getHostContext()! as common.UIAbilityContext).terminateSelf() }
    catch (error) { this.message = localizedText($r('app.string.text_closing_the_shared_window_failed_please_try')) }
  }

  sourceName(): string {
    if (this.location?.source === 'amap') return localizedText($r('app.string.text_shared_from_amap'))
    if (this.location?.source === 'petal') return localizedText($r('app.string.text_shared_from_petal_maps'))
    return localizedText($r('app.string.text_from_shared_content'))
  }

  locationText(): string {
    if (!this.location) return ''
    if (this.location.address) return this.location.address
    if (this.location.latitude) return localizedText($r('app.string.text_coordinate_2'), String(this.location.latitude), String(this.location.longitude))
    return this.location.rawUrl || localizedText($r('app.string.text_unidentified_address'))
  }

  async loadTasks(config: AppConfig, request: number) {
    this.loadingTasks = true
    try {
      const repositories: Map<string, RepoConfig> = new Map<string, RepoConfig>()
      const results: CoreTask[] = []
      const memoTarget = await FileTargetService.resolve(config, 'memo')
      for (const repository of config.repos) {
        if (isSystemRepository(repository)) continue
        if (request !== this.loadRequest) return
        const reference: CoreOrgFileRef | undefined = memoTarget?.repository.id === repository.id ? { repoId: memoTarget.repo.id, path: memoTarget.path } : undefined
        const queries: CoreQuery[] = shareLocationTaskQueries(reference).map(query => ({ type: 'task', query } as CoreQuery))
        const batch = await NativeCoreService.query([repository], queries, config.todoDefaults, config.coreSettings)
        const tasks: CoreTask[] = batch.flatMap(result => taskResult(result).tasks).sort(compareRecords)
        for (const task of tasks) { results.push(task); repositories.set(task.id, repository) }
      }
      if (request !== this.loadRequest) return
      this.taskRepositories = repositories
      this.tasks = results
    } catch (e) { if (request === this.loadRequest) this.taskMessage = localizedText($r('app.string.text_read_task_failed_re_shared_and_try')) }
    finally { if (request === this.loadRequest) this.loadingTasks = false }
  }

  async createTask() {
    if (this.saving || !this.location) return
    this.saving = true; this.message = ''
    try {
      if (!this.created) {
        const target = await FileTargetService.resolve(this.config, 'inbox')
        if (!target) throw new Error(localizedText($r('app.string.text_inbox_files_are_not_selected_or_are')))
        const label = this.location.label || this.location.address || localizedText($r('app.string.text_share_location'))
        const body = `[[${this.location.uri}][${label}]]`
        const file = await target.repo.file(target.path)
        if (!file.todo.initialState) throw new Error(localizedText($r('app.string.text_target_file_not_available_uncompleted')))
        await NativeCoreService.executeTaskOperations(this.config.repos, {
          operations: [{ type: 'Creation', data: { position: { parent: file.fullPath },
            title: localizedText($r('app.string.text_to'), String(this.request.title || label)), body, state: file.todo.initialState } }],
          fileVersions: [{ repoId: target.repo.id, file: target.path, version: file.fileVersion }]
        }, this.config.todoDefaults, this.config.coreSettings)
        this.created = true
        await DeviceBadgeService.refresh(this.getUIContext().getHostContext()!)
      }
      const context = this.getUIContext().getHostContext()! as common.UIAbilityContext
      await context.startAbility({ bundleName: context.applicationInfo.name, abilityName: 'EntryAbility',
        parameters: { page: 'inbox' } })
      await this.close()
    } catch (e) { this.message = this.created ? localizedText($r('app.string.text_job_created_inbox_opened_failed_tap_open')) : (e as Error).message || localizedText($r('app.string.text_failed_to_create_task')) }
    finally { this.saving = false }
  }

  async updateTask() {
    if (this.saving || !this.selectedTask || !this.location || this.location.kind === 'unknown') return
    const task = this.selectedTask!
    const oldUri = this.selectedUri
    const uri = this.location.uri
    const repository = this.taskRepositories.get(task.id)
    if (!repository) { this.message = localizedText($r('app.string.text_the_mission_s_repository_is_not_available')); return }
    this.saving = true; this.message = ''
    try {
      if (!this.updated) {
        await NativeCoreService.executeTaskOperations(this.config.repos, {
          operations: [{ type: 'Modification', data: { path: task.fullPath,
            modifications: [{ field: 'ADDRESS_LINK', value: { oldUri, newUri: uri } }] } }],
          fileVersions: [{ repoId: task.repoId, file: task.filePath, version: task.fileVersion }]
        }, this.config.todoDefaults, this.config.coreSettings)
        this.updated = true
      }
      const context = this.getUIContext().getHostContext()! as common.UIAbilityContext
      await context.startAbility({ bundleName: context.applicationInfo.name, abilityName: 'EntryAbility',
        parameters: { page: 'inbox' } })
      await this.close()
    } catch (e) { this.message = this.updated ? localizedText($r('app.string.text_address_updated_failed_to_open_inbox_try')) : (e as Error).message || localizedText($r('app.string.text_failed_to_update_address')) }
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
            Text(this.location.label || localizedText($r('app.string.text_share_location'))).fontSize(19).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
            Text(this.locationText()).fontSize(14).fontColor(UiColor.secondary).maxLines(2)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }
        Text(this.location.kind === 'unknown' ? localizedText($r('app.string.text_unable_to_confirm_address')) : this.location.kind === 'coordinates' ? localizedText($r('app.string.text_coordinate_identified')) : localizedText($r('app.string.text_address_identified')))
          .fontSize(13).fontColor(this.location.kind === 'unknown' ? UiColor.error : UiColor.primary).width('100%')
      }.width('100%').padding(16).backgroundColor(UiColor.field).borderRadius(16)
    }
  }

  @Builder
  updateView() {
    Column({ space: 12 }) {
      ListSectionHeader({ title: localizedText($r('app.string.text_update_address')) })
      ForEach(this.tasks, (task: CoreTask) => {
        Column({ space: 6 }) {
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
                .fontSize(20).fontColor(UiColor.text).width(24).height(24).textAlign(TextAlign.Center)
            }.width('100%').padding({ right: 8, top: 6, bottom: 6 }).constraintSize({ minHeight: 36 })
              .backgroundColor(this.selectedUri === link.uri && this.selectedTask?.id === task.id ? '#3B5550' : Color.Transparent)
              .borderRadius(8).enabled(!this.saving && !this.updated)
              .onClick(() => { this.selectedTask = task; this.selectedUri = link.uri })
          })
        }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .backgroundColor(UiColor.field).borderRadius(12)
      })
      if (!this.loadingTasks && this.selectedTask) {
        Button(this.saving ? localizedText($r('app.string.text_saving_3')) : this.updated ? localizedText($r('app.string.text_open_inbox')) : localizedText($r('app.string.text_update_selected_addresses'))).width('100%').height(52).backgroundColor(UiColor.primary)
          .fontColor(UiColor.onPrimary)
          .enabled(!this.saving).onClick(() => { this.updateTask() })
      }
    }.width('100%')
  }

  build() {
    Column() {
      Row() {
        Text($r('app.string.text_cancel')).fontSize(16).fontColor(UiColor.secondary).onClick(() => { this.close() })
        Text($r('app.string.text_share_location'))
          .fontSize(20).fontWeight(FontWeight.Medium).fontColor(UiColor.text).layoutWeight(1).textAlign(TextAlign.Center)
        Blank().width(42)
      }.width('100%').height(64).padding({ left: 20, right: 20 })
      Divider().color(UiColor.outline)
      Scroll() {
        Column({ space: 16 }) {
          if (this.loading) {
            Text($r('app.string.text_reading_shared_content')).fontSize(18).fontColor(UiColor.text).padding(24)
          } else {
            Text(this.sourceName()).fontSize(14).fontColor(UiColor.primary).width('100%').padding({ top: 18 })
            this.locationCard()
            if (this.location?.kind === 'unknown') {
              Text($r('app.string.text_the_shared_content_does_not_confirm_the')).fontSize(14).fontColor(UiColor.warning).width('100%')
              Button(this.saving ? localizedText($r('app.string.text_saving_3')) : this.created ? localizedText($r('app.string.text_open_inbox')) : localizedText($r('app.string.text_create_tasks_and_save_original_links'))).width('100%').height(50)
                .backgroundColor(UiColor.field).fontColor(UiColor.text).enabled(!this.saving).onClick(() => { this.createTask() })
            } else {
              Button(this.saving ? localizedText($r('app.string.text_saving_3')) : this.created ? localizedText($r('app.string.text_open_inbox')) : localizedText($r('app.string.text_create_task'))).width('100%').height(52).backgroundColor(UiColor.primary)
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
