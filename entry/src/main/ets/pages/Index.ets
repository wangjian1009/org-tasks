// 存储库同步，以及从设置进入的系统日历同步

import { router } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { MessageBar, PreferenceRow } from '../components/Controls'
import { UiColor } from '../ui/Theme'
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit'
import { CalendarSync } from '../services/CalendarSync'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { preferences } from '@kit.ArkData'
import { CoreBridgeError, CoreConflict, coreErrorMessage, CoreWebDavSyncEvent, NativeCoreService } from '../services/NativeCoreService'
import { AppConfigService, APP_CONFIG_PREFERENCES } from '../services/AppConfigService'

interface SyncParams { calendar?: boolean }

@Entry
@Component
struct Index {
  @State calendarMode: boolean = false
  @State syncing: boolean = false
  @State lastSync: string = '尚未同步'
  @State taskCount: number = 0
  @State syncMessage: string = ''
  @State conflicts: CoreConflict[] = []
  @State drawerOpen: boolean = false
  @State loading: boolean = true
  @State config: AppConfig = DEFAULT_CONFIG

  private calendarSync: CalendarSync | undefined = undefined

  onPageShow() {
    if (this.syncing) return
    this.calendarMode = (router.getParams() as SyncParams | undefined)?.calendar === true
    this.loadConfig()
  }
  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return this.syncing
  }

  async loadConfig() {
    this.loading = true
    try {
      const context = getContext(this)
      this.config = await AppConfigService.load(context)

      const workspace = await NativeCoreService.loadWorkspace(this.config.repos, this.config.todoDefaults)
      this.taskCount = workspace.tasks.length
      this.conflicts = this.calendarMode ? [] : await NativeCoreService.conflicts(this.config.repos, this.config.todoDefaults)

      if (this.calendarMode) {
        this.calendarSync = new CalendarSync(context, this.config.calendarName)
        const store = await preferences.getPreferences(context, APP_CONFIG_PREFERENCES)
        const lastSyncTime = await store.get('lastSyncTime', 0) as number
        if (lastSyncTime > 0) {
          const d = new Date(lastSyncTime)
          this.lastSync = `${d.getMonth() + 1}/${d.getDate()} ${d.getHours()}:${d.getMinutes().toString().padStart(2, '0')}`
        }
      }
    } catch (e) {
      this.syncMessage = `加载配置失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally {
      this.loading = false
    }
  }

  async doSync() {
    if (this.syncing || this.loading) return
    if (this.config.repos.length === 0) { this.syncMessage = '请先添加存储库'; return }

    this.syncing = true
    this.syncMessage = '正在同步...'
    try {
      if (this.calendarMode && !await this.requestSyncPermissions()) {
        this.syncMessage = '需要日历权限才能同步'
        this.syncing = false
        return
      }

      const hasWebDav = !this.calendarMode && this.config.repos.some((repository) => repository.webdavEnabled)
      this.syncMessage = hasWebDav ? '正在同步 WebDAV…' : '正在读取本地文件…'
      const workspace = hasWebDav
        ? await NativeCoreService.syncWorkspaceWebDav(this.config.repos, (event: CoreWebDavSyncEvent) => this.updateWebDavProgress(event), this.config.todoDefaults)
        : await NativeCoreService.loadWorkspace(this.config.repos, this.config.todoDefaults)
      this.taskCount = workspace.tasks.length

      if (!this.calendarMode) {
        this.conflicts = []
        this.syncMessage = `同步完成，已读取 ${this.taskCount} 条笔记`
        return
      }

      // 初始化日历
      this.syncMessage = '正在写入日历...'
      if (!this.calendarSync) {
        this.syncMessage = '配置尚未加载完成'
        this.syncing = false
        return
      }
      const ok = await this.calendarSync.init()
      if (!ok) {
        this.syncMessage = '无法初始化日历，请检查权限'
        this.syncing = false
        return
      }

      const result = await this.calendarSync.syncTasks(workspace.tasks)

      // 保存同步时间
      const context = getContext(this)
      const store = await preferences.getPreferences(context, APP_CONFIG_PREFERENCES)
      await store.put('lastSyncTime', Date.now())
      await store.flush()
      const now = new Date()
      this.lastSync = `${now.getMonth() + 1}/${now.getDate()} ${now.getHours()}:${now.getMinutes().toString().padStart(2, '0')}`

      this.syncMessage = `同步完成: ${result.synced}/${result.total} 个任务（新增 ${result.created}，更新 ${result.updated}，删除 ${result.deleted}）`

      if (result.errors.length > 0) {
        this.syncMessage += `\n${result.errors.length} 个错误`
      }
    } catch (e) {
      this.syncMessage = `同步失败：${coreErrorMessage(e as CoreBridgeError)}`
      if (!this.calendarMode) {
        try { this.conflicts = await NativeCoreService.conflicts(this.config.repos, this.config.todoDefaults) } catch (_) {}
      }
    } finally {
      this.syncing = false
    }
  }

  private async requestSyncPermissions(): Promise<boolean> {
    const context = getContext(this)
    const manager = abilityAccessCtrl.createAtManager()
    const permissions: Permissions[] = [
      'ohos.permission.READ_CALENDAR' as Permissions,
      'ohos.permission.WRITE_CALENDAR' as Permissions
    ]
    const requestResult = await manager.requestPermissionsFromUser(context, permissions)
    for (const authResult of requestResult.authResults) {
      if (authResult !== 0) {
        return false
      }
    }
    return true
  }

  private updateWebDavProgress(event: CoreWebDavSyncEvent) {
    switch (event.type) {
      case 'listingStarted':
        this.syncMessage = '正在读取 WebDAV 文件列表...'
        break
      case 'listed':
        this.syncMessage = `已发现 ${event.files} 个远端文件`
        break
      case 'fileStarted':
        this.syncMessage = `正在同步 ${event.index + 1}/${event.total}: ${event.path}`
        break
      case 'fileProcessed':
        this.syncMessage = `已处理 ${event.path}`
        break
      case 'finished':
        this.syncMessage = `WebDAV 同步${event.result === 'succeeded' ? '完成' : '结束'}，共 ${event.files} 个文件`
        break
    }
  }

  build() {
    Column() {
      AppShell({ title: this.calendarMode ? '同步到系统日历' : '同步', activeRoute: this.calendarMode ? 'pages/Settings' : 'pages/Index',
        back: this.calendarMode, drawerOpen: $drawerOpen, busy: this.syncing,
        actionIcon: $r('app.media.ui_settings'), actionLabel: this.calendarMode ? '' : '同步设置', action: (): void => { router.pushUrl({ url: 'pages/Settings' }) } }) {
        Column() {
          Scroll() {
            Column({ space: 20 }) {
              Column({ space: 10 }) {
                Image($r('app.media.ui_sync')).width(36).height(36)
                Text(this.syncing ? '正在同步' : this.calendarMode ? (this.lastSync === '尚未同步' ? '等待首次同步' : `上次同步 ${this.lastSync}`) : '存储库文件同步')
                  .fontSize(24).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
                Text(this.calendarMode ? '本地 Org 笔记本 → 系统日历' : 'WebDAV ↔ 本地 Org 文件').fontSize(14).fontColor(UiColor.secondary)
                if (this.syncing) { LoadingProgress().width(28).height(28).color(UiColor.primary) }
              }.width('100%').padding(24).borderRadius(20).backgroundColor(UiColor.container)
              Row() {
                Column({ space: 6 }) {
                  Text(`${this.taskCount}`).fontSize(30).fontColor(UiColor.primary)
                  Text('条笔记').fontSize(13).fontColor(UiColor.secondary)
                }.layoutWeight(1)
                Column({ space: 6 }) {
                  Text(this.calendarMode ? this.config.calendarName : `${this.config.repos.length}`).fontSize(18).fontColor(UiColor.text).maxLines(1)
                  Text(this.calendarMode ? '目标日历' : '个存储库').fontSize(13).fontColor(UiColor.secondary)
                }.layoutWeight(1)
              }.width('100%')
              MessageBar({ message: this.syncMessage, error: this.syncMessage.includes('失败') || this.syncMessage.includes('错误') })
              ForEach(this.conflicts, (conflict: CoreConflict) => {
                PreferenceRow({ title: `处理同步冲突（${conflict.paths.length} 个文件）`, detail: conflict.paths.join('、'),
                  icon: $r('app.media.ui_sync'), action: (): void => {
                    router.pushUrl({ url: 'pages/MergeConflict', params: { repoId: conflict.repoId, syncId: conflict.syncId } })
                  } })
              }, (conflict: CoreConflict) => `${conflict.repoId}:${conflict.syncId}`)
              if (this.calendarMode) {
                Text('使用本地文件中的任务。需要获取远端更新时，请先从导航中的“同步”同步存储库。')
                  .width('100%').fontSize(13).lineHeight(21).fontColor(UiColor.secondary)
              }
              Button(this.syncing ? '同步中…' : this.calendarMode ? '同步到系统日历' : '立即同步').width('100%').height(48).backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary)
                .enabled(!this.syncing && !this.loading && this.config.repos.length > 0).onClick((): void => { this.doSync() })
              if (this.config.repos.length === 0 && !this.loading) {
                Button('添加存储库').width('100%').height(48).backgroundColor(UiColor.selected).fontColor(UiColor.onSelected)
                  .onClick((): void => { router.pushUrl({ url: 'pages/Repositories' }) })
              }
              Divider().color(UiColor.outline)
              PreferenceRow({ title: '存储库', detail: `${this.config.repos.length} 个本地或 WebDAV 存储库`, icon: $r('app.media.ui_cloud'),
                action: (): void => { router.pushUrl({ url: 'pages/Repositories' }) } })
              PreferenceRow({ title: '日程', detail: '查看有计划与截止时间的未完成笔记', icon: $r('app.media.ui_calendar'),
                action: (): void => { router.replaceUrl({ url: 'pages/Agenda' }) } })
            }.width('100%').padding(16).enabled(!this.syncing)
          }.width('100%').height('100%').align(Alignment.TopStart)
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
