import { defaultTodoSettings, Workspace } from 'liborg_tasks_harmony.so'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { BackgroundSyncService } from '../services/BackgroundSyncService'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, coreErrorMessage, NativeCoreService, CoreTaskState, CoreSettingsObject } from '../services/NativeCoreService'
import { AppShell } from '../components/AppShell'
import { MessageBar, PreferenceRow, SectionHeading } from '../components/Controls'
import { UiColor, repositoryLabel } from '../ui/Theme'
import { configuredFileTarget, FileTargetKind } from '../services/FileTargetService'
import { TaskStateCategory, taskStateCategoryLabel } from '../ui/TaskStatePresentation'
import { common } from '@kit.AbilityKit'
import { NotificationPermissionService, NotificationPermissionState } from '../services/NotificationPermissionService'

interface SettingsParams { section?: string }

@Entry
@Component
struct Settings {
  @State config: AppConfig = DEFAULT_CONFIG
  @State section: string = ''
  @State calendarName: string = 'Org Tasks'
  @State syncInterval: string = '20'
  @State todoDefaults: string = ''
  @State coreSettings: CoreSettingsObject = { additionStates: [] }
  private stateCategories: TaskStateCategory[] = [TaskStateCategory.Todo, TaskStateCategory.Doing, TaskStateCategory.Wait, TaskStateCategory.Done, TaskStateCategory.Cancle]
  @State categoryDrafts: string[] = ['', '', '', '', '']
  @State categoryBusy: boolean = false
  @State fileDisplayMode: 'rendered' | 'source' = 'rendered'
  @State saving: boolean = false
  @State loaded: boolean = false
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State notificationState: NotificationPermissionState | 'loading' | 'error' = 'loading'
  @State notificationBusy: boolean = false
  private notificationRevision: number = 0
  private notificationVisible: boolean = false
  private notificationTimer: number = -1
  private saveTimer: number = -1
  private saveRequested: boolean = false

  onPageShow() {
    this.notificationVisible = true
    this.load()
    this.loadNotificationState()
    this.scheduleNotificationCheck()
  }
  onPageHide() { this.stopNotificationCheck() }
  aboutToDisappear() { this.stopNotificationCheck() }

  private scheduleNotificationCheck(): void {
    if (!this.notificationVisible || this.notificationTimer !== -1) return
    this.notificationTimer = setTimeout(async (): Promise<void> => {
      this.notificationTimer = -1
      if (!this.notificationVisible) return
      // 系统半屏设置不保证触发页面或窗口生命周期，只检查权限，不重复读取任务。
      if (this.section === '应用程序' && NotificationPermissionService.isForeground()) await this.loadNotificationState(true)
      this.scheduleNotificationCheck()
    }, 1000)
  }

  private stopNotificationCheck(): void {
    this.notificationVisible = false
    this.notificationRevision++
    if (this.notificationTimer !== -1) clearTimeout(this.notificationTimer)
    this.notificationTimer = -1
  }

  async loadNotificationState(refreshBadge: boolean = false): Promise<void> {
    const revision = ++this.notificationRevision
    try {
      const context = this.getUIContext().getHostContext()!
      const state = await NotificationPermissionService.state(context)
      if (revision !== this.notificationRevision) return
      const previous = this.notificationState
      this.notificationState = state
      if (refreshBadge && state === 'enabled' && previous !== 'enabled') await NotificationPermissionService.refresh(context)
    } catch (_) {
      if (revision === this.notificationRevision) this.notificationState = 'error'
    }
  }

  notificationDetail(): string {
    if (this.notificationBusy) return '正在处理…'
    if (this.notificationState === 'enabled') return '通知已开启 · 管理系统通知设置'
    if (this.notificationState === 'disabled') return '通知未开启 · 前往系统设置'
    if (this.notificationState === 'unrequested') return '开启通知'
    if (this.notificationState === 'error') return '状态读取失败 · 点击重试'
    return '正在读取…'
  }

  async manageNotifications(): Promise<void> {
    if (this.notificationBusy || this.notificationState === 'loading') return
    this.notificationBusy = true
    try {
      if (this.notificationState !== 'error') {
        await NotificationPermissionService.manage(this.getUIContext().getHostContext()! as common.UIAbilityContext)
      }
      await this.loadNotificationState()
    } catch (error) {
      this.message = `更新通知设置失败：${coreErrorMessage(error as CoreBridgeError)}`
      await this.loadNotificationState()
    } finally { this.notificationBusy = false }
  }
  onBackPress(): boolean {
    if (this.saveTimer >= 0) {
      clearTimeout(this.saveTimer)
      this.saveTimer = -1
      this.save()
      return true
    }
    if (this.saving || this.categoryBusy) return true
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    if (this.section) { this.section = ''; this.message = ''; return true }
    return false
  }

  async load() {
    try {
      this.config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      if (!this.loaded) {
        const params = this.getUIContext().getRouter().getParams() as SettingsParams | undefined
        if (params?.section) this.section = params.section
        this.todoDefaults = this.config.todoDefaults
        this.coreSettings = this.config.coreSettings
        this.fileDisplayMode = this.config.fileDisplayMode
        this.calendarName = this.config.calendarName
        this.syncInterval = Math.max(20, this.config.syncInterval).toString()
      }
      this.loaded = true
    } catch (e) { this.message = `读取设置失败：${coreErrorMessage(e as CoreBridgeError)}` }
  }

  fileTargetDetail(kind: FileTargetKind): string {
    const target = configuredFileTarget(this.config, kind)
    if (!target.path) return '未选择'
    const repository = this.config.repos.find(repo => repo.id === target.repoId)
    if (!repository) return `需要重新选择 · ${target.path}`
    return `${repositoryLabel(repository)} / ${target.path}`
  }

  scheduleSave() {
    if (!this.loaded) return
    this.saveRequested = true
    if (this.saveTimer >= 0) clearTimeout(this.saveTimer)
    this.saveTimer = setTimeout((): void => {
      this.saveTimer = -1
      if (!this.saving) this.save()
    }, 250)
  }

  async save() {
    if (!this.loaded) return
    this.saveRequested = true
    if (this.saving) return
    this.saving = true
    try {
      while (this.saveRequested) {
        this.saveRequested = false
        const interval = Number(this.syncInterval)
        if (!this.calendarName.trim() || !Number.isInteger(interval) || interval < 20) {
          this.message = '请填写日历名称，同步间隔应为至少 20 的整数'
          break
        }
        const current = await AppConfigService.load(this.getUIContext().getHostContext()!)
        const todoChanged = current.todoDefaults !== this.todoDefaults || JSON.stringify(current.coreSettings) !== JSON.stringify(this.coreSettings)
        current.calendarName = this.calendarName.trim()
        current.syncInterval = interval
        current.todoDefaults = this.todoDefaults
        current.coreSettings = this.coreSettings
        current.fileDisplayMode = this.fileDisplayMode
        await AppConfigService.save(this.getUIContext().getHostContext()!, current)
        if (todoChanged) {
          await NativeCoreService.workspaceFor(current.repos, this.todoDefaults, this.coreSettings)
          this.config = current
        }
        this.message = '设置已保存'
        try { await BackgroundSyncService.configure(interval) }
        catch (e) { this.message = `设置已保存，后台调度更新失败：${coreErrorMessage(e as CoreBridgeError)}` }
      }
    } catch (e) { this.message = `保存设置失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally {
      this.saving = false
      if (this.saveRequested) this.save()
    }
  }

  categoryExtras(index: number): CoreTaskState[] {
    return this.coreSettings.additionStates.filter(state => state.category === this.stateCategories[index])
  }

  async changeCategory(index: number, remove?: string): Promise<void> {
    if (this.categoryBusy) return
    const name = this.categoryDrafts[index].trim()
    if (!remove && !name) { this.message = '请输入状态值'; return }
    this.categoryBusy = true
    try {
      const additions = this.coreSettings.additionStates.filter(state => state.name !== remove)
      if (!remove) additions.push({ name, category: this.stateCategories[index] })
      const candidate: CoreSettingsObject = { additionStates: additions }
      const workspace = new Workspace()
      await workspace.setSettings(candidate)
      this.coreSettings = await workspace.getSettings()
      this.categoryDrafts = this.categoryDrafts.map((value, position) => position === index ? '' : value)
      this.scheduleSave()
    } catch (error) { this.message = `更新状态分类失败：${coreErrorMessage(error as CoreBridgeError)}` }
    finally { this.categoryBusy = false }
  }

  build() {
    Column() {
      AppShell({ title: this.section || '设置', activeRoute: 'pages/Settings', drawerOpen: $drawerOpen,
        back: false, busy: this.saving, titleIcon: $r('app.media.nav_settings') }) {
        Column() {
          MessageBar({ message: this.message, error: this.message !== '设置已保存' })
          Scroll() {
            Column() {
              if (!this.section) {
                PreferenceRow({ title: '笔记与笔记本', icon: $r('app.media.ui_folder'), action: () => { this.section = '笔记与笔记本' } })
                PreferenceRow({ title: '应用程序', icon: $r('app.media.ui_info'), action: () => { this.section = '应用程序' } })
              } else if (this.section === '笔记与笔记本') {
                SectionHeading({ title: '文件展示' })
                PreferenceRow({ title: '文件展示方式', detail: this.fileDisplayMode === 'source' ? '原文' : '渲染（默认）', icon: $r('app.media.ui_body'),
                  action: (): void => {
                    this.getUIContext().showActionSheet({ title: '文件展示方式', message: '选择打开文件时的展示方式，修改后立即保存。', sheets: [
                      { title: '渲染（默认）', action: (): void => { this.fileDisplayMode = 'rendered'; this.scheduleSave() } },
                      { title: '原文', action: (): void => { this.fileDisplayMode = 'source'; this.scheduleSave() } }
                    ] })
                  } })
                SectionHeading({ title: '默认 TODO 流程' })
                Column({ space: 12 }) {
                  TextArea({ text: this.todoDefaults, placeholder: '从 Rust 获取的默认设置，可按 Org 声明编辑' }).width('100%').height(180)
                    .fontFamily('monospace').backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary).borderRadius(6)
                    .onChange((value: string) => { this.todoDefaults = value; this.scheduleSave() })
                  Text('使用 TODO、SEQ_TODO 或 TYP_TODO 声明，每行一套流程；文件内流程整体覆盖默认流程。状态分类通过下方配置项设置；文件可用 TASK_STATE_CATEGORY 声明分类。留空表示默认不识别 TODO 状态。')
                    .fontSize(13).fontColor(UiColor.secondary).lineHeight(21).width('100%')
                  Button('恢复默认 TODO 设置').fontSize(14).backgroundColor(UiColor.selected).fontColor(UiColor.onSelected)
                    .onClick(async (): Promise<void> => {
                      try { this.todoDefaults = await defaultTodoSettings(); this.scheduleSave() }
                      catch (e) { this.message = `读取默认设置失败：${coreErrorMessage(e as CoreBridgeError)}` }
                    })
                }.width('100%').padding({ left: 24, right: 24 })
                SectionHeading({ title: '任务状态分类' })
                Column({ space: 20 }) {
                  Text('默认状态不可修改；可为每个分类添加其他状态值。状态还需出现在文件或默认 TODO 流程中，才会识别为任务。')
                    .fontSize(13).fontColor(UiColor.secondary).lineHeight(21).width('100%')
                  ForEach(this.stateCategories, (category: TaskStateCategory, index: number) => {
                    Column({ space: 8 }) {
                      Text(`${taskStateCategoryLabel(category)} · ${category}`)
                        .fontSize(16).fontColor(UiColor.text).width('100%')
                      Text('内置默认状态不可修改')
                        .fontSize(13).fontColor(UiColor.secondary).width('100%')
                      ForEach(this.categoryExtras(index), (state: CoreTaskState) => {
                        Row() {
                          Text(state.name).fontSize(14).fontColor(UiColor.text).layoutWeight(1)
                          Button('移除').fontSize(13).fontColor(UiColor.secondary).backgroundColor(Color.Transparent)
                            .onClick(() => { this.changeCategory(index, state.name) })
                        }.width('100%')
                      }, (state: CoreTaskState) => state.name)
                      Row({ space: 8 }) {
                        TextInput({ text: this.categoryDrafts[index], placeholder: '添加状态值' })
                          .layoutWeight(1).backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary)
                          .onChange((value: string) => { this.categoryDrafts = this.categoryDrafts.map((draft, position) => position === index ? value : draft) })
                        Button('添加').fontSize(14).backgroundColor(UiColor.selected).fontColor(UiColor.onSelected)
                          .onClick(() => { this.changeCategory(index) })
                      }.width('100%')
                    }.width('100%')
                  }, (category: TaskStateCategory) => category)
                }.width('100%').padding({ left: 24, right: 24 }).enabled(!this.categoryBusy)
                SectionHeading({ title: '文件入口' })
                Column({ space: 16 }) {
                  PreferenceRow({ title: '收件箱文件', detail: this.fileTargetDetail('inbox'), icon: $r('app.media.nav_inbox'), action: (): void => { this.getUIContext().getRouter().pushUrl({ url: 'pages/FileTargetPicker', params: { kind: 'inbox' } }) } })
                  Text('收件箱展示所选仓库中的文件；未配置时点击入口提示设置。').fontSize(13).fontColor(UiColor.secondary).lineHeight(21).width('100%')
                  PreferenceRow({ title: '某天文件', detail: this.fileTargetDetail('someday'), icon: $r('app.media.nav_someday'), action: (): void => { this.getUIContext().getRouter().pushUrl({ url: 'pages/FileTargetPicker', params: { kind: 'someday' } }) } })
                  Text('“某天”展示所选文件中具有有效待办状态的任务。').fontSize(13).fontColor(UiColor.secondary).lineHeight(21).width('100%')
                  PreferenceRow({ title: '备忘文件', detail: this.fileTargetDetail('memo'), icon: $r('app.media.nav_memo'), action: (): void => { this.getUIContext().getRouter().pushUrl({ url: 'pages/FileTargetPicker', params: { kind: 'memo' } }) } })
                  Text('“备忘”展示所选文件中的全部标题记录。').fontSize(13).fontColor(UiColor.secondary).lineHeight(21).width('100%')
                }.width('100%').padding(24)
              } else {
                SectionHeading({ title: '小清单' })
                Text('浏览 Org 笔记本、按日期查看任务，并将任务同步到 HarmonyOS 系统日历。')
                  .fontSize(16).fontColor(UiColor.secondary).lineHeight(26).width('100%').padding(24)
                SectionHeading({ title: '通知与角标' })
                PreferenceRow({ title: '通知与角标', detail: this.notificationDetail(), icon: $r('app.media.ui_info'),
                  action: (): void => { this.manageNotifications() } })
                Text('在桌面图标显示收件箱、截止任务和冲突的数量。数字角标还需在系统设置中开启桌面角标。')
                  .fontSize(13).fontColor(UiColor.secondary).lineHeight(21).width('100%').padding({ left: 24, right: 24, bottom: 16 })
              }
            }.width('100%').padding({ bottom: 32 }).enabled(this.loaded)
          }.width('100%').layoutWeight(1).align(Alignment.TopStart)
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
