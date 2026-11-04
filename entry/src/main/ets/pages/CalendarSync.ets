// 设置中的系统日历同步；存储库同步由共享前台会话执行。

import { router } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { MessageBar } from '../components/Controls'
import { UiColor } from '../ui/Theme'
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit'
import { CalendarSync } from '../services/CalendarSync'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { preferences } from '@kit.ArkData'
import { CoreBridgeError, coreErrorMessage, NativeCoreService } from '../services/NativeCoreService'
import { AppConfigService, APP_CONFIG_PREFERENCES } from '../services/AppConfigService'

@Entry
@Component
struct CalendarSyncPage {
  @State syncing: boolean = false
  @State lastSync: string = '尚未同步'
  @State taskCount: number = 0
  @State syncMessage: string = ''
  @State drawerOpen: boolean = false
  @State loading: boolean = true
  @State config: AppConfig = DEFAULT_CONFIG

  private calendarSync: CalendarSync | undefined = undefined

  onPageShow() {
    if (this.syncing) return
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
      this.calendarSync = new CalendarSync(context, this.config.calendarName)
      const store = await preferences.getPreferences(context, APP_CONFIG_PREFERENCES)
      const lastSyncTime = await store.get('lastSyncTime', 0) as number
      if (lastSyncTime > 0) {
        const d = new Date(lastSyncTime)
        this.lastSync = `${d.getMonth() + 1}/${d.getDate()} ${d.getHours()}:${d.getMinutes().toString().padStart(2, '0')}`
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
      if (!await this.requestSyncPermissions()) {
        this.syncMessage = '需要日历权限才能同步'
        this.syncing = false
        return
      }

      this.syncMessage = '正在读取本地文件…'
      const workspace = await NativeCoreService.loadWorkspace(this.config.repos, this.config.todoDefaults)
      this.taskCount = workspace.tasks.length

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

  build() {
    Column() {
      AppShell({ title: '同步到系统日历', activeRoute: 'pages/CalendarSync',
        back: true, drawerOpen: $drawerOpen, busy: this.syncing }) {
        Column() {
          Scroll() {
            Column({ space: 20 }) {
              Column({ space: 10 }) {
                Image($r('app.media.ui_sync')).width(36).height(36)
                Text(this.syncing ? '正在同步' : (this.lastSync === '尚未同步' ? '等待首次同步' : `上次同步 ${this.lastSync}`))
                  .fontSize(24).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
                Text('本地 Org 笔记本 → 系统日历').fontSize(14).fontColor(UiColor.secondary)
                if (this.syncing) { LoadingProgress().width(28).height(28).color(UiColor.primary) }
              }.width('100%').padding(24).borderRadius(20).backgroundColor(UiColor.container)
              Row() {
                Column({ space: 6 }) {
                  Text(`${this.taskCount}`).fontSize(30).fontColor(UiColor.primary)
                  Text('条笔记').fontSize(13).fontColor(UiColor.secondary)
                }.layoutWeight(1)
                Column({ space: 6 }) {
                  Text(this.config.calendarName).fontSize(18).fontColor(UiColor.text).maxLines(1)
                  Text('目标日历').fontSize(13).fontColor(UiColor.secondary)
                }.layoutWeight(1)
              }.width('100%')
              MessageBar({ message: this.syncMessage, error: this.syncMessage.includes('失败') || this.syncMessage.includes('错误') })
              Text('使用本地文件中的任务。需要获取远端更新时，请先从侧边栏点击“同步”。')
                .width('100%').fontSize(13).lineHeight(21).fontColor(UiColor.secondary)
              Button(this.syncing ? '同步中…' : '同步到系统日历').width('100%').height(48).backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary)
                .enabled(!this.syncing && !this.loading && this.config.repos.length > 0).onClick((): void => { this.doSync() })
              if (this.config.repos.length === 0 && !this.loading) {
                Button('添加存储库').width('100%').height(48).backgroundColor(UiColor.selected).fontColor(UiColor.onSelected)
                  .onClick((): void => { router.pushUrl({ url: 'pages/Repositories' }) })
              }
            }.width('100%').padding(16).enabled(!this.syncing)
          }.width('100%').height('100%').align(Alignment.TopStart)
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
