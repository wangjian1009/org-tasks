import { ReminderOperationList } from '../components/ReminderOperationList'
import { SettingsAutoSave } from '../services/SettingsAutoSave'
import { ReminderManager, TaskReminderConfiguration, CalendarPermissionState } from '../services/ReminderManager'
import { TaskReminderList } from '../components/TaskReminderList'
import { TrashSettingsService } from '../services/TrashSettingsService'
import { PageNavigator } from '../services/PageNavigator'
import { addRepository } from '../services/RepositoryNavigation'
import { validateConfiguration } from 'liborg_tasks_harmony.so'
import { LengthMetrics } from '@kit.ArkUI'
import { common } from '@kit.AbilityKit'
import { AppConfig, AppLinkAssociation, DEFAULT_CONFIG, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
import { AppLinkService } from '../services/AppLinkService'
import { CoreBridgeError, coreErrorMessage, NativeCoreService, CoreTaskState, CoreSettingsObject } from '../services/NativeCoreService'
import { NotebookGroup, NotebookService } from '../services/NotebookService'
import { AppShell } from '../components/AppShell'
import { MessageBar } from '../components/controls/MessageBar'
import { SettingsGroup } from '../components/controls/SettingsGroup'
import { SettingsRow } from '../components/controls/SettingsRow'
import { SettingsChoiceRow } from '../components/controls/SettingsChoiceRow'
import { PopupMenuItem } from '../components/controls/PopupMenu'
import { FileTargetSheet } from '../components/editors/FileTargetSheet'
import { UiColor, repositoryLabel } from '../ui/Theme'
import { configuredFileTarget, FileTargetKind } from '../services/FileTargetService'
import { TaskStateCategory, taskStateCategoryLabel } from '../ui/TaskStatePresentation'
import { isSystemRepository } from '../models/SystemRepository'
import { NotificationPermissionService, NotificationPermissionState } from '../services/NotificationPermissionService'

interface SettingsParams { section?: string }

@Entry
@Component
struct Settings {
  @State config: AppConfig = DEFAULT_CONFIG
  @State section: string = ''
  @State reminderEnabled: boolean = false
  @State reminderSummary: string = ''
  private stopReminder: (() => void) | undefined = undefined
  private reminderSaved: TaskReminderConfiguration = { enabled: false, eventDurationMinutes: 5 }
  @State eventDurationDraft: string = '5'
  private savedRetentionDays: number = 30
  private reminderEditVersion: number = 0
  private preferenceSave: SettingsAutoSave = new SettingsAutoSave((error: Error): void => {
    if (this.notificationVisible) this.message = coreErrorMessage(error as CoreBridgeError)
  })
  @State retentionDraft: string = '30'
  @State coreSettings: CoreSettingsObject = { additionStates: [] }
  @State defaultStates: CoreTaskState[] = []
  private stateCategories: TaskStateCategory[] = [TaskStateCategory.Todo, TaskStateCategory.Doing, TaskStateCategory.Wait, TaskStateCategory.Done, TaskStateCategory.Cancel]
  @State categoryDraft: string = ''
  @State editingCategory: number = -1
  @State categoryBusy: boolean = false
  @State fileDisplayMode: 'rendered' | 'source' = 'rendered'
  @State saving: boolean = false
  @State loaded: boolean = false
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State filePickerOpen: boolean = false
  @State filePickerBusy: boolean = false
  @State filePickerKind: FileTargetKind = 'inbox'
  @State notebooks: NotebookGroup[] = []
  @State appLinks: AppLinkAssociation[] = []
  @State editingAppLink: number = -1
  @State appLinkNameDraft: string = ''
  @State appLinkBundleDraft: string = ''
  @State appLinkModuleDraft: string = ''
  @State appLinkAbilityDraft: string = ''
  @State appLinkBusy: boolean = false
  @State notificationState: NotificationPermissionState | 'loading' | 'error' = 'loading'
  @State notificationBusy: boolean = false
  @State calendarState: CalendarPermissionState | 'loading' | 'error' = 'loading'
  @State calendarBusy: boolean = false
  private calendarRevision: number = 0
  private notificationRevision: number = 0
  private notificationVisible: boolean = false
  private notificationTimer: number = -1
  private stopExternalGuard: (() => void) | undefined = undefined

  onPageShow() {
    this.stopExternalGuard?.()
    this.stopExternalGuard = PageNavigator.shared.watchExternalLeaveGuard((): boolean =>
      !this.saving && !this.categoryBusy && !this.filePickerOpen && !this.filePickerBusy &&
      !this.notificationBusy && !this.calendarBusy && !this.appLinkBusy && this.editingCategory < 0 &&
      this.editingAppLink < 0 && !this.preferenceSave.hasPending())
    this.stopReminder?.()
    this.stopReminder = ReminderManager.subscribe((): void => { this.reminderSummary = ReminderManager.summary() })
    this.reminderSummary = ReminderManager.summary()
    this.notificationVisible = true
    this.load()
    this.loadNotificationState()
    this.loadCalendarState()
    this.scheduleNotificationCheck()
  }
  onPageHide() { this.preferenceSave.flush(); this.stopExternalGuard?.(); this.stopExternalGuard = undefined; this.stopNotificationCheck() }
  aboutToDisappear() { this.preferenceSave.flush(); this.stopExternalGuard?.(); this.stopNotificationCheck() }

  private scheduleNotificationCheck(): void {
    if (!this.notificationVisible || this.notificationTimer !== -1) return
    this.notificationTimer = setTimeout(async (): Promise<void> => {
      this.notificationTimer = -1
      if (!this.notificationVisible) return
      // 系统半屏设置不保证触发页面或窗口生命周期，只检查权限，不重复读取任务。
      if ((this.section === '' || this.section === '应用程序' || this.section === '任务提醒') && NotificationPermissionService.isForeground()) await this.loadNotificationState(true)
      if (this.section === '任务提醒' && NotificationPermissionService.isForeground()) await this.loadCalendarState(true)
      this.scheduleNotificationCheck()
    }, 1000)
  }

  private stopNotificationCheck(): void {
    this.stopReminder?.(); this.stopReminder = undefined
    this.notificationVisible = false
    this.notificationRevision++; this.calendarRevision++
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
      if (refreshBadge && state === 'enabled' && previous !== 'enabled') {
        await NotificationPermissionService.refresh(context)
      }
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
    if (this.notificationBusy || this.calendarBusy || this.notificationState === 'loading') return
    this.notificationBusy = true
    this.message = ''
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
  notificationActionTitle(): string {
    if (this.notificationState === 'unrequested') return '开启通知'
    if (this.notificationState === 'error') return '重试'
    return '前往系统设置'
  }
  async loadCalendarState(refreshEvents: boolean = false): Promise<void> {
    const revision = ++this.calendarRevision
    try {
      const previous = this.calendarState
      const state = await ReminderManager.permissionState()
      if (revision !== this.calendarRevision || !this.notificationVisible) return
      this.calendarState = state
      if (refreshEvents && state !== previous) await ReminderManager.refresh()
    } catch (_) { if (revision === this.calendarRevision) this.calendarState = 'error' }
  }
  calendarDetail(): string {
    if (this.calendarBusy) return '正在处理…'
    if (this.calendarState === 'enabled') return '日历读写已允许'
    if (this.calendarState === 'error') return '读取失败 · 点击重试'
    if (this.calendarState === 'loading') return '正在读取…'
    return '未授权 · 点击授权'
  }
  async manageCalendar(): Promise<void> {
    if (this.calendarBusy || this.calendarState === 'loading') return
    this.calendarBusy = true; this.message = ''
    try {
      if (this.calendarState !== 'error') await ReminderManager.managePermission()
      await this.loadCalendarState()
      if (this.notificationVisible) await ReminderManager.refresh()
    } catch (error) { this.message = `更新日历授权失败：${coreErrorMessage(error as CoreBridgeError)}` }
    finally { this.calendarBusy = false }
  }
  reminderHelpDetail(): string {
    return '开启后，把未完成任务的提醒时间写入“小清单提醒”专用日历，由系统日历在到点时通知，应用退出后已登记事件仍由系统处理。' +
      '\n\n需要授予日历读写权限。首次使用请打开系统日历完成初始化，并允许系统日历发送通知；小清单自身的通知开关不能替代它。声音和响铃时长由系统日历控制。' +
      '\n\n事件优先采用 SCHEDULED，其次 DEADLINE；都没有时使用提醒时间。日期没有时刻时按零点处理，两项都有时优先 SCHEDULED。最高优先级在日历标题标记为【重要】。' +
      '\n\n事件持续时长默认 5 分钟，可设为 1 至 1440 分钟，修改后自动保存。提醒晚于事件开始时，结束时间至少保留到提醒后的配置时长；清理同时等待提醒过去 30 分钟和事件结束。' +
      '\n\n启动时自动核对事件，之后随任务新增、修改、完成、取消和同步结果自动维护；关闭开关会删除本应用创建的日历事件，不修改任务原文。' +
      `\n\n当前状态：${this.reminderSummary}`
  }
  onBackPress(): boolean {
    if (this.filePickerOpen) { if (!this.filePickerBusy) this.filePickerOpen = false; return true }
    if (this.saving || this.categoryBusy || this.notificationBusy || this.calendarBusy || this.appLinkBusy) return true
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    if (this.editingCategory >= 0) { this.editingCategory = -1; this.categoryDraft = ''; return true }
    if (this.editingAppLink >= 0) { this.cancelAppLinkEdit(); return true }
    if (this.preferenceSave.hasPending()) { this.preferenceSave.flush().then((): void => { this.onBackPress() }); return true }
    if (this.section === '提醒操作日志') { this.section = '任务提醒'; this.message = ''; return true }
    if (this.section) { this.section = ''; this.message = ''; return true }
    PageNavigator.shared.back(this.getUIContext())
    return true
  }

  async load() {
    try {
      await this.preferenceSave.flush()
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      if (!this.loaded) {
        const params = this.getUIContext().getRouter().getParams() as SettingsParams | undefined
        this.section = params?.section === '笔记与笔记本' ? '文件入口' : params?.section || ''
      }
      const reminder = await ReminderManager.configuration()
      this.reminderSaved = reminder
      this.reminderEnabled = reminder.enabled
      this.eventDurationDraft = `${reminder.eventDurationMinutes}`
      this.retentionDraft = `${await TrashSettingsService.retentionDays(this.getUIContext().getHostContext()!)}`
      this.savedRetentionDays = Number(this.retentionDraft)
      this.config = config
      this.appLinks = await AppLinkService.load(this.getUIContext().getHostContext()!)
      this.coreSettings = config.coreSettings
      this.fileDisplayMode = config.fileDisplayMode
      this.defaultStates = await NativeCoreService.defaultTaskStates()
      this.loaded = true
      if (this.section === '文件入口') await this.loadNotebookNames()
    } catch (e) { this.message = `读取设置失败：${coreErrorMessage(e as CoreBridgeError)}` }
  }

  async loadNotebookNames() {
    try { this.notebooks = await NotebookService.list(this.config) }
    catch (_) { this.notebooks = [] }
  }

  openSection(section: string) {
    if (this.preferenceSave.hasPending()) { this.preferenceSave.flush().then((): void => { this.openSection(section) }); return }
    this.section = section
    this.message = ''
    if (section === '文件入口') this.loadNotebookNames()
  }

  beginAppLinkEdit(index: number): void {
    const value = this.appLinks[index]
    if (!value) return
    this.editingAppLink = index
    this.appLinkNameDraft = value.name
    this.appLinkBundleDraft = value.bundleName
    this.appLinkModuleDraft = value.moduleName
    this.appLinkAbilityDraft = value.abilityName
    this.message = ''
  }

  cancelAppLinkEdit(): void {
    if (this.appLinkBusy) return
    this.editingAppLink = -1
    this.message = ''
  }

  async saveAppLink(index: number): Promise<void> {
    if (this.appLinkBusy || !this.appLinks[index]) return
    const value: AppLinkAssociation = { name: this.appLinkNameDraft.trim(), bundleName: this.appLinkBundleDraft.trim(),
      moduleName: this.appLinkModuleDraft.trim(), abilityName: this.appLinkAbilityDraft.trim() }
    if (!value.name || !value.bundleName) { this.message = '请填写应用名称和 Bundle Name'; return }
    this.appLinkBusy = true; this.message = ''
    try {
      await AppLinkService.update(this.getUIContext().getHostContext()!, this.appLinks[index].name, value)
      this.appLinks = await AppLinkService.load(this.getUIContext().getHostContext()!)
      this.editingAppLink = -1
    } catch (error) { this.message = `保存应用关联失败：${(error as Error).message || '请重试'}` }
    finally { this.appLinkBusy = false }
  }

  deleteAppLink(index: number): void {
    if (this.appLinkBusy || !this.appLinks[index]) return
    const value = this.appLinks[index]
    this.getUIContext().showAlertDialog({ title: '删除应用关联？', message: `以后点击 app:${value.name} 时需要重新选择应用。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', fontColor: UiColor.error, action: (): void => { this.removeAppLink(value.name) } } })
  }

  private async removeAppLink(name: string): Promise<void> {
    this.appLinkBusy = true; this.message = ''
    try {
      await AppLinkService.remove(this.getUIContext().getHostContext()!, name)
      this.appLinks = await AppLinkService.load(this.getUIContext().getHostContext()!)
      this.editingAppLink = -1
    } catch (error) { this.message = `删除应用关联失败：${(error as Error).message || '请重试'}` }
    finally { this.appLinkBusy = false }
  }

  fileTargetTitle(kind: FileTargetKind): string {
    const target = configuredFileTarget(this.config, kind)
    if (!target.path) return '未选择'
    const group = this.notebooks.find((item: NotebookGroup) => item.configId === target.repoId)
    return group?.files.find(file => file.path === target.path)?.title || target.path
  }

  fileTargetDetail(kind: FileTargetKind): string {
    const target = configuredFileTarget(this.config, kind)
    if (!target.path) return ''
    const repo = this.config.repos.find((item: RepoConfig) => item.id === target.repoId)
    return repo ? `${repositoryLabel(repo)} · ${target.path}` : `原存储库已移除 · ${target.path}`
  }

  openFilePicker(kind: FileTargetKind) {
    this.filePickerKind = kind
    this.filePickerOpen = true
  }

  async changeDisplayMode(mode: 'rendered' | 'source') {
    if (this.saving || mode === this.fileDisplayMode) return
    this.saving = true
    this.message = ''
    try {
      const current = await AppConfigService.load(this.getUIContext().getHostContext()!)
      current.fileDisplayMode = mode
      await AppConfigService.save(this.getUIContext().getHostContext()!, current)
      this.config = current
      this.fileDisplayMode = mode
    } catch (e) { this.message = `保存失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.saving = false }
  }

  displayModeChoices(): PopupMenuItem[] {
    return [
      { title: '渲染', checked: this.fileDisplayMode === 'rendered', action: (): void => { this.changeDisplayMode('rendered') } },
      { title: '原文', checked: this.fileDisplayMode === 'source', action: (): void => { this.changeDisplayMode('source') } }
    ]
  }

  categoryStates(index: number, defaults: boolean): CoreTaskState[] {
    return (defaults ? this.defaultStates : this.coreSettings.additionStates)
      .filter((state: CoreTaskState) => state.category === this.stateCategories[index])
  }

  async changeCategory(index: number, remove?: string): Promise<void> {
    if (this.categoryBusy) return
    const name = this.categoryDraft.trim()
    if (!remove && !name) { this.message = '请输入状态值'; return }
    this.categoryBusy = true
    this.message = ''
    try {
      const current = await AppConfigService.load(this.getUIContext().getHostContext()!)
      const additions = current.coreSettings.additionStates.filter((state: CoreTaskState) => state.name !== remove)
      if (!remove) additions.push({ name, category: this.stateCategories[index] })
      current.coreSettings = await validateConfiguration({ coreSettings: { additionStates: additions } })
      await AppConfigService.save(this.getUIContext().getHostContext()!, current)
      this.config = current
      this.coreSettings = current.coreSettings
      this.editingCategory = -1
      this.categoryDraft = ''
      await NativeCoreService.workspaceFor(current.repos, current.todoDefaults, current.coreSettings)
    } catch (e) { this.message = `更新状态分类失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.categoryBusy = false }
  }

  @Builder
  filePicker() {
    FileTargetSheet({ kind: this.filePickerKind, busy: $filePickerBusy,
      saved: (): void => { this.filePickerOpen = false; this.load() } })
  }

  @Builder
  homepage() {
    SettingsGroup({ title: '数据与同步' }) {
      SettingsRow({ title: '存储库', value: `${this.config.repos.filter(repo => !isSystemRepository(repo)).length} 个`, icon: $r('app.media.nav_repository'), divider: false,
        action: (): void => { this.openSection('存储库') } })
    }
    SettingsGroup({ title: '任务与笔记' }) {
      SettingsRow({ title: '文件入口', icon: $r('app.media.ui_folder'), action: (): void => { this.openSection('文件入口') } })
      SettingsRow({ title: '废纸篓', value: `${this.savedRetentionDays} 天`, icon: $r('app.media.ui_trash'), action: (): void => { this.openSection('废纸篓') } })
      SettingsRow({ title: '任务状态分类', value: '5 类', icon: $r('app.media.ui_state'), action: (): void => { this.openSection('任务状态分类') } })
      SettingsChoiceRow({ title: '文件展示方式', value: this.fileDisplayMode === 'source' ? '原文' : '渲染',
        icon: $r('app.media.ui_body'), divider: false, disabled: this.saving, items: this.displayModeChoices() })
      SettingsRow({ title: '应用关联', value: `${this.appLinks.length} 个`, icon: $r('app.media.ui_link_other'), divider: false,
        action: (): void => { this.openSection('应用关联') } })
    }
    SettingsGroup({ title: '应用程序', detail: '通知授权和通知类型可在系统设置中管理；数字角标还需在系统设置中开启桌面角标。' }) {
      SettingsRow({ title: '通知与角标', value: this.notificationState === 'enabled' ? '已开启' : this.notificationState === 'loading' ? '读取中' : '未开启',
        detail: this.notificationState === 'error' ? '读取失败，点击重试' : '', icon: $r('app.media.ui_info'),
        action: (): void => { this.manageNotifications() } })
      SettingsRow({ title: '任务提醒', value: this.reminderEnabled ? '已开启' : '已关闭', icon: $r('app.media.ui_reminder'),
        action: (): void => { this.openSection('任务提醒') } })
      SettingsRow({ title: '关于小清单', icon: $r('app.media.ui_info'), divider: false, action: (): void => { this.openSection('关于小清单') } })
    }
  }

  private changeReminder(enabled: boolean): void {
    this.reminderEnabled = enabled; this.message = ''
    const version = ++this.reminderEditVersion
    this.preferenceSave.schedule('reminder', (): Promise<void> => this.saveReminders(enabled, version), 0)
  }
  private changeEventDuration(value: string): void {
    this.eventDurationDraft = value; this.message = ''
    this.preferenceSave.schedule('reminderDuration', (): Promise<void> => this.saveEventDuration(value))
  }
  private async saveEventDuration(value: string): Promise<void> {
    if (!/^\d+$/.test(value)) throw new Error('事件持续时长须为 1 至 1440 分钟的整数')
    const minutes = Number(value)
    await ReminderManager.setEventDurationMinutes(minutes)
    this.reminderSaved = { enabled: this.reminderSaved.enabled, eventDurationMinutes: minutes }
  }
  private changeRetention(value: string): void {
    this.retentionDraft = value; this.message = ''
    this.preferenceSave.schedule('trash', (): Promise<void> => this.saveRetention(value))
  }
  private async saveReminders(enabled: boolean, version: number): Promise<void> {
    try {
      this.calendarBusy = true
      try {
        await ReminderManager.setEnabled(enabled)
        this.reminderSaved = { enabled, eventDurationMinutes: this.reminderSaved.eventDurationMinutes }
        await this.loadCalendarState()
      } finally { this.calendarBusy = false }
    } catch (error) {
      if (version === this.reminderEditVersion) this.reminderEnabled = this.reminderSaved.enabled
      throw error as Error
    }
  }
  private async saveRetention(value: string): Promise<void> {
    if (!/^\d+$/.test(value)) throw new Error('请输入整数天数')
    await TrashSettingsService.saveRetentionDays(this.getUIContext().getHostContext()!, Number(value))
    this.savedRetentionDays = Number(value)
  }
  @Builder
  taskReminderSettings() {
    SettingsGroup({ title: '本机任务提醒', detail: this.reminderHelpDetail() }) {
      Row() {
        Text('启用任务提醒').fontSize(16).fontColor(UiColor.text).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.reminderEnabled }).id('reminder_global_enabled')
          .enabled(!this.calendarBusy)
          .onChange((value: boolean): void => { if (value !== this.reminderEnabled) this.changeReminder(value) })
      }.width('100%').padding(16)
      Text(this.reminderSummary).id('reminder_service_status').fontSize(13).fontColor(UiColor.secondary)
        .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 12 })
      Row({ space: 12 }) {
        Text('事件持续时长（分钟）').fontSize(16).fontColor(UiColor.text).layoutWeight(1)
        TextInput({ text: this.eventDurationDraft, placeholder: '5' }).type(InputType.Number).width(96)
          .id('reminder_event_duration').fontSize(16).fontColor(UiColor.text).backgroundColor(UiColor.field)
          .onChange((value: string): void => { if (value !== this.eventDurationDraft) this.changeEventDuration(value) })
          .onBlur((): void => { this.preferenceSave.flush() })
      }.width('100%').padding(16)
      SettingsRow({ title: '日历授权', value: this.calendarDetail(), action: (): void => { this.manageCalendar() } })
      SettingsRow({ title: '提醒操作日志', icon: $r('app.media.nav_logbook'), divider: false,
        action: (): void => { this.openSection('提醒操作日志') } }).id('reminder_operation_entry')
    }
    SettingsGroup({ title: '有提醒的任务', detail: '与全局事件管理器共用同一任务数据集，展示设置了提醒时间的未完成任务，保留提醒时间已过的记录，排除完成和取消状态；按提醒时间排序，点击可修改或清除。' }) {
      TaskReminderList()
    }
  }
  @Builder
  trashSettings() {
    SettingsGroup({ title: '保留天数', detail: '默认保留 30 天，可设置 1 至 3650 天。打开废纸篓或笔记本时，按删除时间自动永久清除过期记录。删除时间缺失的记录会保留。' }) {
      TextInput({ text: this.retentionDraft, placeholder: '保留天数' }).type(InputType.Number)
        .id('trash_retention_days').onChange((value: string): void => { if (value !== this.retentionDraft) this.changeRetention(value) })
        .onBlur((): void => { this.preferenceSave.flush() })
    }
  }

  @Builder
  fileEntries() {
    SettingsGroup({ title: '入口笔记本', detail: '选择笔记本后，对应入口展示其中的记录。点选文件并确认后生效。' }) {
      SettingsRow({ title: '收件箱', value: this.fileTargetTitle('inbox'), detail: this.fileTargetDetail('inbox'), icon: $r('app.media.nav_inbox'), action: (): void => { this.openFilePicker('inbox') } })
      SettingsRow({ title: '某天', value: this.fileTargetTitle('someday'), detail: this.fileTargetDetail('someday'), icon: $r('app.media.nav_someday'), action: (): void => { this.openFilePicker('someday') } })
      SettingsRow({ title: '备忘', value: this.fileTargetTitle('memo'), detail: this.fileTargetDetail('memo'), icon: $r('app.media.nav_memo'), divider: false, action: (): void => { this.openFilePicker('memo') } })
    }
  }

  @Builder
  appLinksSettings() {
    SettingsGroup({ title: 'app: 链接关联', detail: 'Org 链接使用 app:名称 表示外部应用。第一次点击时从随版本发布的银行应用目录中选择并自动保存；这里只能修改或删除已经建立的关联，不能手动新增。' }) {
      if (this.appLinks.length === 0) {
        Text('尚未建立应用关联。点击 Org 中的 app: 链接后即可选择并保存。').fontSize(14).fontColor(UiColor.secondary)
          .width('100%').padding(16)
      }
      ForEach(this.appLinks, (value: AppLinkAssociation, index: number) => {
        if (this.editingAppLink === index) {
          Column({ space: 8 }) {
            TextInput({ text: this.appLinkNameDraft, placeholder: '应用名称（app: 后的值）' }).fontSize(14).backgroundColor(UiColor.field)
              .onChange((text: string): void => { this.appLinkNameDraft = text })
            TextInput({ text: this.appLinkBundleDraft, placeholder: 'Bundle Name' }).fontSize(14).backgroundColor(UiColor.field)
              .onChange((text: string): void => { this.appLinkBundleDraft = text })
            TextInput({ text: this.appLinkModuleDraft, placeholder: 'Module Name（可选）' }).fontSize(14).backgroundColor(UiColor.field)
              .onChange((text: string): void => { this.appLinkModuleDraft = text })
            TextInput({ text: this.appLinkAbilityDraft, placeholder: 'Ability Name' }).fontSize(14).backgroundColor(UiColor.field)
              .onChange((text: string): void => { this.appLinkAbilityDraft = text })
            Row({ space: 12 }) {
              Button('取消').height(40).backgroundColor(UiColor.field).fontColor(UiColor.text).onClick((): void => { this.cancelAppLinkEdit() })
              Button('保存').height(40).backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary).onClick((): void => { this.saveAppLink(index) })
            }.justifyContent(FlexAlign.End).width('100%')
          }.width('100%').padding(14)
        } else {
          SettingsRow({ title: `app:${value.name}`, value: value.bundleName, detail: `${value.moduleName ? value.moduleName + ' · ' : ''}${value.abilityName}`,
            icon: $r('app.media.ui_link_other'), action: (): void => { this.beginAppLinkEdit(index) }, disabled: this.appLinkBusy })
        }
      }, (value: AppLinkAssociation) => value.name)
      if (this.editingAppLink >= 0) {
        SettingsRow({ title: '删除当前关联', icon: $r('app.media.ui_delete'), divider: false, danger: true,
          action: (): void => { this.deleteAppLink(this.editingAppLink) }, disabled: this.appLinkBusy })
      }
    }
  }

  @Builder
  categories() {
    SettingsGroup({ title: '状态分类', detail: '默认状态固定；带 × 的自定义状态可点击移除。点击 + 添加状态，新增状态还需在笔记本的 TODO 声明中启用。' }) {
      ForEach(this.stateCategories, (category: TaskStateCategory, index: number) => {
        Column({ space: 8 }) {
          Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
            space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(4) } }) {
            Text(taskStateCategoryLabel(category)).fontSize(16).fontColor(UiColor.text)
            ForEach(this.categoryStates(index, true), (state: CoreTaskState) => {
              Text(state.name).fontFamily('monospace').fontSize(13).fontColor(UiColor.text)
                .padding({ left: 8, right: 8, top: 5, bottom: 5 }).borderRadius(6)
                .border({ width: 0.5, color: UiColor.outline }).accessibilityText(`${state.name}，默认，只读`)
            }, (state: CoreTaskState) => state.name)
            ForEach(this.categoryStates(index, false), (state: CoreTaskState) => {
              Button(`${state.name}  ×`).fontSize(13).fontFamily('monospace').height(32).borderRadius(6)
                .padding({ left: 8, right: 8 }).constraintSize({ maxWidth: '100%' })
                .fontColor(UiColor.text).backgroundColor(UiColor.field).accessibilityText(`移除自定义状态 ${state.name}`)
                .onClick((): void => { this.changeCategory(index, state.name) })
            }, (state: CoreTaskState) => state.name)
            Button('+').fontSize(22).width(36).height(36).padding(0)
              .backgroundColor(Color.Transparent).fontColor(UiColor.primary)
              .accessibilityText(`为${taskStateCategoryLabel(category)}添加状态`)
              .onClick((): void => { this.editingCategory = index; this.categoryDraft = ''; this.message = '' })
          }.width('100%')
          if (this.editingCategory === index) {
            Row({ space: 8 }) {
              TextInput({ text: this.categoryDraft, placeholder: '输入状态值' }).layoutWeight(1).height(44)
                .backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary)
                .onChange((value: string): void => { this.categoryDraft = value })
              Button('添加').height(44).fontSize(14).backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary)
                .onClick((): void => { this.changeCategory(index) })
            }.width('100%')
          }
        }.width('100%').padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .border({ width: { bottom: index < this.stateCategories.length - 1 ? 0.5 : 0 }, color: UiColor.divider })
      }, (category: TaskStateCategory) => category)
    }
  }

  @Builder
  repositories() {
    SettingsGroup({ title: '已配置的存储库', detail: '管理本地文件目录和 WebDAV 连接。浏览文件请使用侧边栏的“笔记本”。' }) {
      if (this.config.repos.filter(repo => !isSystemRepository(repo)).length === 0) {
        Text('尚未配置存储库').fontSize(14).fontColor(UiColor.secondary).width('100%').padding(16)
      }
      ForEach(this.config.repos.filter(repo => !isSystemRepository(repo)), (repo: RepoConfig) => {
        SettingsRow({ title: repositoryLabel(repo), value: repo.webdavEnabled ? 'WebDAV' : '不同步', detail: repo.rootDirectory,
          icon: $r('app.media.nav_repository'),
          action: (): void => { PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/RepositorySettings', params: { repoId: repo.id } }) } })
      }, (repo: RepoConfig) => repo.id)
      SettingsRow({ title: '添加存储库', icon: $r('app.media.ui_add'), divider: false,
        action: (): void => { addRepository(this.getUIContext()) } })
    }
  }

  build() {
    Column() {
      AppShell({ title: this.section || '设置', activeRoute: 'pages/Settings', drawerOpen: $drawerOpen,
        back: this.section.length > 0 || PageNavigator.shared.path.depth > 1, busy: this.saving || this.categoryBusy || this.filePickerBusy || this.appLinkBusy,
        backAction: (): void => { this.onBackPress() }, titleIcon: $r('app.media.nav_settings') }) {
        Column() {
          MessageBar({ message: this.message, error: true })
          Scroll() {
            Column() {
              if (!this.loaded && this.message) {
                Button('重新读取设置').height(44).backgroundColor(UiColor.selected).fontColor(UiColor.onSelected).margin(24)
                  .onClick((): void => { this.message = ''; this.load() })
              } else if (!this.loaded) {
                LoadingProgress().width(32).height(32).color(UiColor.primary).margin(24)
              } else if (!this.section) { this.homepage() }
              else if (this.section === '任务提醒') { this.taskReminderSettings() }
              else if (this.section === '提醒操作日志') {
                SettingsGroup({ title: '本次运行', detail: '按最新操作在前显示系统提醒的新增、修改和删除记录，包括触发原因、执行结果和失败原因。仅保留本次运行的最近 500 条记录，重启应用后清空。' }) {
                  ReminderOperationList()
                }
              }
              else if (this.section === '废纸篓') { this.trashSettings() }
              else if (this.section === '文件入口') { this.fileEntries() }
              else if (this.section === '任务状态分类') { this.categories() }
              else if (this.section === '存储库') { this.repositories() }
              else if (this.section === '应用关联') { this.appLinksSettings() }
              else {
                SettingsGroup({ title: '小清单' }) {
                  Text('浏览 Org 笔记本、按日期查看任务，支持 WebDAV 同步和快速捕捉。')
                    .fontSize(16).fontColor(UiColor.secondary).lineHeight(26).width('100%').padding(16)
                }
              }
            }.width('100%').padding({ left: 16, right: 16, bottom: 32 }).enabled(!this.saving && !this.categoryBusy)
          }.width('100%').layoutWeight(1).align(Alignment.TopStart)
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
      .bindSheet($$this.filePickerOpen, this.filePicker, {
        height: '70%', detents: ['70%', '90%'], preferType: SheetType.BOTTOM,
        backgroundColor: UiColor.container, showClose: true,
        onWillDismiss: (action): void => { if (!this.filePickerBusy) action.dismiss() }
      })
  }
}
