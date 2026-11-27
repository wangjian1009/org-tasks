import { localizedText } from '../ui/LocalizedText'
import { showDangerousConfirmation } from '../components/controls/DangerousConfirmation'
import { ReminderOperationList } from '../components/ReminderOperationList'
import { SettingsAutoSave } from '../services/SettingsAutoSave'
import { ReminderManager, TaskReminderConfiguration, CalendarPermissionState } from '../services/ReminderManager'
import { TaskReminderList } from '../components/TaskReminderList'
import { TrashSettingsService } from '../services/TrashSettingsService'
import { PageNavigator, primaryPage } from '../services/PageNavigator'
import { addRepository } from '../services/RepositoryNavigation'
import { validateConfiguration } from 'liborg_tasks_harmony.so'
import { LengthMetrics } from '@kit.ArkUI'
import { common } from '@kit.AbilityKit'
import { picker } from '@kit.CoreFileKit'
import { AppConfig, AppLinkAssociation, AppLinkCatalogEntry, DEFAULT_CONFIG, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
import { CONFIG_FILE_EXTENSION, ConfigTransfer } from '../services/ConfigTransfer'
import { AppDataManager } from '../services/AppDataManager'
import { AppLinkManager, AppLinkTargetStatus, appLinkName } from '../services/AppLinkService'
import { CoreBridgeError, coreErrorMessage, NativeCoreService, CoreTaskState, CoreSettingsObject } from '../services/NativeCoreService'
import { NotebookGroup, NotebookService } from '../services/NotebookService'
import { AppShell } from '../components/AppShell'
import { MessageBar } from '../components/controls/MessageBar'
import { EmptyState } from '../components/controls/EmptyState'
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
import { AppLanguage, loadAppLanguage, saveAppLanguage } from '../services/AppLanguage'

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
  @State appLanguage: AppLanguage | undefined = undefined
  @State languageMenuOpen: boolean = false
  @State saving: boolean = false
  @State loaded: boolean = false
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State filePickerOpen: boolean = false
  @State filePickerBusy: boolean = false
  @State filePickerKind: FileTargetKind = 'inbox'
  @State notebooks: NotebookGroup[] = []
  @State appLinks: AppLinkAssociation[] = []
  @State appLinkBusy: boolean = false
  @State appLinkPickerOpen: boolean = false
  @State appLinkPickerBusy: boolean = false
  @State appLinkCandidateError: string = ''
  @State appLinkCandidates: AppLinkCatalogEntry[] = []
  @State appLinkPickerName: string = ''
  @State appLinkPickerBundle: string = ''
  @State appLinkCatalog: AppLinkCatalogEntry[] | undefined = undefined
  @State requiredAppLinks: string[] = []
  @State appLinkTargets: Map<string, AppLinkTargetStatus> = new Map()
  private stopAppLinkTasks: (() => void) | undefined = undefined
  private appLinkTargetRevision: number = 0
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
      !this.notificationBusy && !this.calendarBusy && !this.appLinkBusy && !this.appLinkPickerOpen && !this.appLinkPickerBusy && this.editingCategory < 0 &&
      !this.preferenceSave.hasPending())
    this.stopReminder?.()
    this.stopReminder = ReminderManager.subscribe((): void => { this.reminderSummary = ReminderManager.summary() })
    this.reminderSummary = ReminderManager.summary()
    this.notificationVisible = true
    this.load()
    this.loadLanguage()
    this.loadNotificationState()
    this.loadCalendarState()
    this.scheduleNotificationCheck()
  }
  onPageHide() { this.preferenceSave.flush(); this.stopExternalGuard?.(); this.stopExternalGuard = undefined; this.stopNotificationCheck(); this.stopAppLinkTasks?.() }
  aboutToDisappear() { this.preferenceSave.flush(); this.stopExternalGuard?.(); this.stopNotificationCheck(); this.stopAppLinkTasks?.() }

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
    if (this.notificationBusy) return localizedText($r('app.string.text_processing'))
    if (this.notificationState === 'enabled') return localizedText($r('app.string.text_notification_is_open_management_systems_notification_settings'))
    if (this.notificationState === 'disabled') return localizedText($r('app.string.text_notifier_not_started_go_to_system_settings'))
    if (this.notificationState === 'unrequested') return localizedText($r('app.string.text_open_notification'))
    if (this.notificationState === 'error') return localizedText($r('app.string.text_status_reading_failed_tap_to_try_again'))
    return localizedText($r('app.string.text_reading'))
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
      this.message = localizedText($r('app.string.text_update_of_notification_settings_failed'), String(coreErrorMessage(error as CoreBridgeError)))
      await this.loadNotificationState()
    } finally { this.notificationBusy = false }
  }
  notificationActionTitle(): string {
    if (this.notificationState === 'unrequested') return localizedText($r('app.string.text_open_notification'))
    if (this.notificationState === 'error') return localizedText($r('app.string.text_retry'))
    return localizedText($r('app.string.text_go_to_system_settings'))
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
    if (this.calendarBusy) return localizedText($r('app.string.text_processing'))
    if (this.calendarState === 'enabled') return localizedText($r('app.string.text_calendar_reading_and_writing_is_allowed'))
    if (this.calendarState === 'error') return localizedText($r('app.string.text_reading_failed_tap_to_try_again'))
    if (this.calendarState === 'loading') return localizedText($r('app.string.text_reading'))
    return localizedText($r('app.string.text_unauthorized_tap_authorization'))
  }
  async manageCalendar(): Promise<void> {
    if (this.calendarBusy || this.calendarState === 'loading') return
    this.calendarBusy = true; this.message = ''
    try {
      if (this.calendarState !== 'error') await ReminderManager.managePermission()
      await this.loadCalendarState()
      if (this.notificationVisible) await ReminderManager.refresh()
    } catch (error) { this.message = localizedText($r('app.string.text_couldn_t_update_calendar_permissions'), String(coreErrorMessage(error as CoreBridgeError))) }
    finally { this.calendarBusy = false }
  }
  reminderHelpDetail(): string {
    return localizedText($r('app.string.text_upon_opening_write_uncompleted_alarms_into_a')) +
      localizedText($r('app.string.text_you_need_to_give_calendar_reading_and')) +
      localizedText($r('app.string.text_the_event_is_preferred_to_scheduled_followed')) +
      localizedText($r('app.string.text_the_event_lasts_for_5_minutes_with')) +
      localizedText($r('app.string.text_automatically_check_events_on_start_up_and')) +
      localizedText($r('app.string.text_current_status'), String(this.reminderSummary))
  }
  onBackPress(): boolean {
    if (this.appLinkPickerOpen) { if (!this.appLinkBusy && !this.appLinkPickerBusy) this.appLinkPickerOpen = false; return true }
    if (this.filePickerOpen) { if (!this.filePickerBusy) this.filePickerOpen = false; return true }
    if (this.saving || this.categoryBusy || this.notificationBusy || this.calendarBusy || this.appLinkBusy || this.appLinkPickerBusy) return true
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    if (this.editingCategory >= 0) { this.editingCategory = -1; this.categoryDraft = ''; return true }
    if (this.preferenceSave.hasPending()) { this.preferenceSave.flush().then((): void => { this.onBackPress() }); return true }
    if (this.section === '提醒操作日志') { this.section = '任务提醒'; this.message = ''; return true }
    if (this.section) {
      const params = this.getUIContext().getRouter().getParams() as SettingsParams | undefined
      if (params?.section === this.section && PageNavigator.shared.path.depth > 1) {
        PageNavigator.shared.back(this.getUIContext())
      } else {
        this.section = ''
        this.message = ''
      }
      return true
    }
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
      this.appLinks = await AppLinkManager.shared.load(this.getUIContext().getHostContext()!, true)
      this.coreSettings = config.coreSettings
      this.fileDisplayMode = config.fileDisplayMode
      this.defaultStates = await NativeCoreService.defaultTaskStates()
      this.loaded = true
      this.watchAppLinkTasks()
      if (this.section === '文件入口') await this.loadNotebookNames()
      if (this.section === '应用关联') await this.refreshAppLinkTargets()
    } catch (e) { this.message = localizedText($r('app.string.text_reading_settings_failed'), String(coreErrorMessage(e as CoreBridgeError))) }
  }

  async loadNotebookNames() {
    try { this.notebooks = await NotebookService.list(this.config) }
    catch (_) { this.notebooks = [] }
  }

  private sectionTitle(): string {
    switch (this.section) {
      case '废纸篓': return localizedText($r('app.string.text_trash'))
      case '存储库': return localizedText($r('app.string.text_repositories'))
      case '文件入口': return localizedText($r('app.string.text_notebook_shortcuts'))
      case '任务状态分类': return localizedText($r('app.string.text_task_status_categories'))
      case '应用程序': return localizedText($r('app.string.text_app'))
      case '应用关联': return localizedText($r('app.string.text_app_links'))
      case '任务提醒': return localizedText($r('app.string.text_task_reminders'))
      case '提醒操作日志': return localizedText($r('app.string.text_reminder_activity'))
      case '关于小清单': return localizedText($r('app.string.text_about_org_tasks'))
      default: return localizedText($r('app.string.text_settings'))
    }
  }

  openSection(section: string) {
    if (this.preferenceSave.hasPending()) { this.preferenceSave.flush().then((): void => { this.openSection(section) }); return }
    this.section = section
    this.message = ''
    if (section === '文件入口') this.loadNotebookNames()
    if (section === '应用关联') this.refreshAppLinkTargets()
  }

  deleteAppLink(name: string): void {
    if (this.appLinkBusy || this.appLinkPickerBusy) return
    showDangerousConfirmation(this.getUIContext(), { title: localizedText($r('app.string.text_untie_the_application')), message: localizedText($r('app.string.text_re_select_applications_when_you_tap_the'), String(name)),
      confirmLabel: localizedText($r('app.string.text_untie')), onConfirm: (): void => { this.removeAppLink(name) } })
  }

  private async removeAppLink(name: string): Promise<void> {
    this.appLinkBusy = true; this.message = ''
    try {
      await AppLinkManager.shared.remove(this.getUIContext().getHostContext()!, name)
      await this.refreshAppLinks()
      this.appLinkPickerOpen = false
    } catch (error) { this.message = localizedText($r('app.string.text_failed_to_delete_application_connection'), String((error as Error).message || localizedText($r('app.string.text_please_try_again')))) }
    finally { this.appLinkBusy = false }
  }

  private watchAppLinkTasks(): void {
    this.stopAppLinkTasks?.()
    const manager = AppDataManager.shared(this.getUIContext().getHostContext()!)
    const source = manager.dataSet('appLinkTasks')
    const update = (): void => {
      const data = source.data
      const names = new Set<string>()
      if (data?.type === 'task') {
        for (const task of data.result.tasks) {
          for (const link of task.appLinks ?? []) {
            const name = appLinkName(link.uri)
            if (name) names.add(name)
          }
        }
      }
      const links = Array.from(names)
      if (JSON.stringify(this.requiredAppLinks) !== JSON.stringify(links)) this.requiredAppLinks = links
    }
    this.stopAppLinkTasks = source.subscribe(update)
    update()
  }

  private appLinkNames(): string[] {
    const configured = this.requiredAppLinks.filter((name: string): boolean => this.appLinkCatalog?.some(
      (app: AppLinkCatalogEntry): boolean => app.launch !== undefined &&
        (app.name === name || app.aliases?.includes(name) === true)) === true)
    return Array.from(new Set(this.appLinks.map((item: AppLinkAssociation): string => item.name).concat(configured)))
  }

  private appLinkBundle(name: string): string {
    return this.appLinks.find((item: AppLinkAssociation): boolean => item.name === name)?.bundleName ?? ''
  }

  private appLinkTargetLabel(bundleName: string): string {
    const status = this.appLinkTargets.get(bundleName)?.availability
    if (status === 'missing') return localizedText($r('app.string.text_not_installed'))
    if (status === 'disabled') return localizedText($r('app.string.text_disabled'))
    if (!this.appLinkCatalog) return localizedText($r('app.string.app_link_bound'))
    return this.appLinkCatalog.find((app: AppLinkCatalogEntry): boolean => app.id === bundleName)?.name ?? localizedText($r('app.string.text_no_such_application_in_directory'))
  }

  private appLinkIcon(bundleName: string): Resource | undefined {
    if (!bundleName) return undefined
    const target = this.appLinkTargets.get(bundleName)?.icon
    if (target) return target
    const app = this.appLinkCatalog?.find((entry: AppLinkCatalogEntry): boolean => entry.id === bundleName)
    return app?.icon ? $rawfile(app.icon) : undefined
  }

  private async refreshAppLinks(): Promise<void> {
    this.appLinks = await AppLinkManager.shared.load(this.getUIContext().getHostContext()!)
    await this.refreshAppLinkTargets()
  }

  private async refreshAppLinkTargets(): Promise<void> {
    const revision = ++this.appLinkTargetRevision
    const context = this.getUIContext().getHostContext()!
    try {
      const catalog = await AppLinkManager.shared.catalog(context)
      if (revision !== this.appLinkTargetRevision) return
      this.appLinkCatalog = catalog
    } catch (_) {
      if (revision !== this.appLinkTargetRevision) return
      this.appLinkCatalog = undefined
    }
    const bundleNames = Array.from(new Set(this.appLinks.map((item: AppLinkAssociation): string => item.bundleName)))
    const statuses = await Promise.all(bundleNames.map((bundleName: string): Promise<AppLinkTargetStatus> =>
      AppLinkManager.shared.targetStatus(bundleName)))
    const targets = new Map<string, AppLinkTargetStatus>()
    bundleNames.forEach((name: string, index: number): void => { targets.set(name, statuses[index]) })
    if (revision === this.appLinkTargetRevision) this.appLinkTargets = targets
  }

  async chooseAppLink(name: string): Promise<void> {
    if (this.appLinkBusy || this.appLinkPickerBusy) return
    this.appLinkPickerName = name
    this.appLinkPickerBundle = this.appLinkBundle(name)
    this.appLinkCandidates = []
    this.appLinkPickerOpen = true
    await this.loadAppLinkCandidates()
  }

  private async loadAppLinkCandidates(): Promise<void> {
    this.appLinkPickerBusy = true; this.message = ''; this.appLinkCandidateError = ''
    try {
      const context = this.getUIContext().getHostContext()!
      this.appLinkCandidates = await AppLinkManager.shared.bindingCandidates(context, this.appLinkPickerName)
    } catch (_) { this.appLinkCandidateError = localizedText($r('app.string.text_applying_the_list_to_read_failed_try')) }
    finally { this.appLinkPickerBusy = false }
  }

  async bindAppLink(app: AppLinkCatalogEntry): Promise<void> {
    if (this.appLinkBusy || this.appLinkPickerBusy || !this.appLinkPickerOpen) return
    this.appLinkPickerBusy = true
    this.appLinkCandidateError = ''
    try {
      const context = this.getUIContext().getHostContext()!
      await AppLinkManager.shared.bind(context, this.appLinkPickerName, app.id)
      this.appLinkPickerOpen = false
      await this.refreshAppLinks()
    } catch (error) { this.appLinkCandidateError = localizedText($r('app.string.text_failed_to_save_application_connection'), String((error as Error).message || localizedText($r('app.string.text_please_try_again')))) }
    finally { this.appLinkPickerBusy = false }
  }

  fileTargetTitle(kind: FileTargetKind): string {
    const target = configuredFileTarget(this.config, kind)
    if (!target.path) return localizedText($r('app.string.text_no_selection'))
    const group = this.notebooks.find((item: NotebookGroup) => item.configId === target.repoId)
    return group?.files.find(file => file.path === target.path)?.title || target.path
  }

  fileTargetDetail(kind: FileTargetKind): string {
    const target = configuredFileTarget(this.config, kind)
    if (!target.path) return ''
    const repo = this.config.repos.find((item: RepoConfig) => item.id === target.repoId)
    return repo ? `${repositoryLabel(repo)} · ${target.path}` : localizedText($r('app.string.text_original_repository_removed'), String(target.path))
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
    } catch (e) { this.message = localizedText($r('app.string.text_save_failed'), String(coreErrorMessage(e as CoreBridgeError))) }
    finally { this.saving = false }
  }

  displayModeChoices(): PopupMenuItem[] {
    return [
      { title: localizedText($r('app.string.text_rendered')), checked: this.fileDisplayMode === 'rendered', action: (): void => { this.changeDisplayMode('rendered') } },
      { title: localizedText($r('app.string.text_source')), checked: this.fileDisplayMode === 'source', action: (): void => { this.changeDisplayMode('source') } }
    ]
  }

  private async loadLanguage(): Promise<void> {
    try { this.appLanguage = await loadAppLanguage(this.getUIContext().getHostContext()!) }
    catch (_) { this.message = localizedText($r('app.string.interface_language_read_failed')) }
  }

  private languageLabel(language: AppLanguage | undefined): string {
    if (language === 'zh-Hans') return localizedText($r('app.string.interface_language_chinese'))
    if (language === 'en') return localizedText($r('app.string.interface_language_english'))
    return localizedText($r('app.string.interface_language_system'))
  }

  private languageMenu(): MenuElement[] {
    const languages: AppLanguage[] = ['default', 'zh-Hans', 'en']
    return languages.map((language: AppLanguage): MenuElement => ({
      value: this.languageLabel(language),
      icon: language === this.appLanguage ? $r('app.media.ui_done') : undefined,
      action: (): void => { this.changeLanguage(language) }
    }))
  }

  private async changeLanguage(language: AppLanguage): Promise<void> {
    this.languageMenuOpen = false
    if (this.saving || this.appLanguage === language) return
    this.saving = true
    this.message = ''
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext
      await this.preferenceSave.flush()
      await saveAppLanguage(context, language)
      this.appLanguage = language
      const ability = context.abilityInfo
      try {
        context.getApplicationContext().restartApp({
          bundleName: ability.bundleName, moduleName: ability.moduleName, abilityName: ability.name
        })
      } catch (_) { this.message = localizedText($r('app.string.interface_language_restart_needed')) }
    } catch (_) { this.message = localizedText($r('app.string.interface_language_save_failed')) }
    finally { this.saving = false }
  }

  categoryStates(index: number, defaults: boolean): CoreTaskState[] {
    return (defaults ? this.defaultStates : this.coreSettings.additionStates)
      .filter((state: CoreTaskState) => state.category === this.stateCategories[index])
  }

  async changeCategory(index: number, remove?: string): Promise<void> {
    if (this.categoryBusy) return
    const name = this.categoryDraft.trim()
    if (!remove && !name) { this.message = localizedText($r('app.string.text_please_enter_a_status_value')); return }
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
    } catch (e) { this.message = localizedText($r('app.string.text_update_status_classification_failed'), String(coreErrorMessage(e as CoreBridgeError))) }
    finally { this.categoryBusy = false }
  }

  @Builder
  filePicker() {
    FileTargetSheet({ kind: this.filePickerKind, busy: $filePickerBusy,
      saved: (): void => { this.filePickerOpen = false; this.load() } })
  }

  @Builder
  homepage() {
    SettingsGroup({ title: localizedText($r('app.string.text_data_sync')) }) {
      SettingsRow({ title: localizedText($r('app.string.text_repositories')), value: localizedText($r('app.string.text_individual'), String(this.config.repos.filter(repo => !isSystemRepository(repo)).length)), icon: $r('app.media.nav_repository'), divider: false,
        action: (): void => { this.openSection('存储库') } })
    }
    SettingsGroup({ title: localizedText($r('app.string.text_tasks_and_notes')) }) {
      SettingsRow({ title: localizedText($r('app.string.text_notebook_shortcuts')), icon: $r('app.media.ui_folder'), action: (): void => { this.openSection('文件入口') } })
      SettingsRow({ title: localizedText($r('app.string.text_trash')), value: localizedText($r('app.string.text_day_2'), String(this.savedRetentionDays)), icon: $r('app.media.ui_trash'), action: (): void => { this.openSection('废纸篓') } })
      SettingsRow({ title: localizedText($r('app.string.text_task_status_categories')), value: localizedText($r('app.string.text_category_5')), icon: $r('app.media.ui_state'), action: (): void => { this.openSection('任务状态分类') } })
      SettingsChoiceRow({ title: localizedText($r('app.string.text_file_view')), value: this.fileDisplayMode === 'source' ? localizedText($r('app.string.text_source')) : localizedText($r('app.string.text_rendered')),
        icon: $r('app.media.ui_body'), divider: false, disabled: this.saving, items: this.displayModeChoices() })
      SettingsRow({ title: localizedText($r('app.string.text_app_links')), value: localizedText($r('app.string.text_individual'), String(this.appLinks.length)), icon: $r('app.media.ui_link_app'), divider: false,
        action: (): void => { this.openSection('应用关联') } })
    }
    SettingsGroup({ title: localizedText($r('app.string.text_app')), detail: localizedText($r('app.string.text_notification_authorization_and_type_of_notification_can')) }) {
      SettingsRow({ title: localizedText($r('app.string.interface_language')), value: this.appLanguage ? this.languageLabel(this.appLanguage) : '',
        icon: $r('app.media.ui_link_web'), disclosureIcon: $r('app.media.ui_down'), disabled: this.saving || !this.appLanguage,
        action: (): void => { this.languageMenuOpen = true } })
        .bindMenu(this.languageMenuOpen, this.languageMenu(), { placement: Placement.BottomRight,
          onDisappear: (): void => { this.languageMenuOpen = false } })
      SettingsRow({ title: localizedText($r('app.string.text_notifications_and_corner_signs')), value: this.notificationState === 'enabled' ? localizedText($r('app.string.text_enabled')) : this.notificationState === 'loading' ? localizedText($r('app.string.text_reading_2')) : localizedText($r('app.string.text_unopened')),
        detail: this.notificationState === 'error' ? localizedText($r('app.string.text_couldn_t_load_tap_to_retry')) : '', icon: $r('app.media.ui_info'),
        action: (): void => { this.manageNotifications() } })
      SettingsRow({ title: localizedText($r('app.string.text_task_reminders')), value: this.reminderEnabled ? localizedText($r('app.string.text_enabled')) : localizedText($r('app.string.text_closed')), icon: $r('app.media.ui_reminder'),
        action: (): void => { this.openSection('任务提醒') } })
      SettingsRow({ title: localizedText($r('app.string.help_center')), icon: $r('app.media.ui_info'),
        action: (): void => { PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/Help' }) } })
      SettingsRow({ title: localizedText($r('app.string.text_about_org_tasks')), icon: $r('app.media.ui_info'), divider: false,
        action: (): void => { this.openHelp('about') } })
    }
  }

  private settingsMenu(): PopupMenuItem[] {
    return [
      { title: localizedText($r('app.string.text_backup')), action: (): void => { this.backupConfiguration() } },
      { title: localizedText($r('app.string.text_import_backup_configuration')), action: (): void => { this.importConfiguration() } },
      { title: localizedText($r('app.string.text_reset')), dangerous: true, action: (): void => { this.confirmReset() } }
    ]
  }

  private async importConfiguration(): Promise<void> {
    if (this.saving) return
    this.saving = true
    this.message = ''
    const ui = this.getUIContext()
    const source = PageNavigator.shared.path
    try {
      const uri = await ConfigTransfer.selectFile(ui.getHostContext()! as common.UIAbilityContext)
      if (!uri || PageNavigator.shared.path !== source) return
      await this.preferenceSave.flush()
      if (PageNavigator.shared.path === source) {
        await PageNavigator.shared.pushPage(ui, { url: 'pages/ConfigImport', params: { configImportUri: uri } })
      }
    } catch (_) {
      if (PageNavigator.shared.path === source) {
        this.message = localizedText($r('app.string.text_cannot_select_profile_please_try_again'))
      }
    } finally { this.saving = false }
  }

  private confirmReset(): void {
    showDangerousConfirmation(this.getUIContext(), { title: localizedText($r('app.string.text_reset_settings')),
      message: localizedText($r('app.string.text_the_application_settings_and_repository_configuration_will')),
      confirmLabel: localizedText($r('app.string.text_reset')), onConfirm: (): void => { this.resetConfiguration() } })
  }

  private async resetConfiguration(): Promise<void> {
    if (this.saving) return
    this.saving = true
    this.message = ''
    try {
      await this.preferenceSave.flush()
      await ConfigTransfer.reset(this.getUIContext().getHostContext()!)
      if (!await PageNavigator.shared.openPrimary(this.getUIContext(), primaryPage('today'))) await this.load()
    } catch (error) { this.message = localizedText($r('app.string.text_reset_failed'), String(coreErrorMessage(error as CoreBridgeError))) }
    finally { this.saving = false }
  }

  private async backupConfiguration(): Promise<void> {
    if (this.saving) return
    this.saving = true
    this.message = ''
    try {
      let destination: number
      try {
        const choice = await this.getUIContext().getPromptAction().showActionMenu({
          title: localizedText($r('app.string.text_backup')), buttons: [
            { text: localizedText($r('app.string.text_documentation')), color: UiColor.text },
            { text: localizedText($r('app.string.text_share')), color: UiColor.text }
          ]
        })
        destination = choice.index
      } catch (_) { return }
      const context = this.getUIContext().getHostContext()! as common.UIAbilityContext
      const title = ConfigTransfer.backupTitle()
      const text = await ConfigTransfer.exportText(context)
      if (destination === 0) {
        const options = new picker.DocumentSaveOptions()
        options.newFileNames = [title + CONFIG_FILE_EXTENSION]
        const result = await new picker.DocumentViewPicker(context).save(options)
        if (result.length > 0) {
          await ConfigTransfer.writeFile(result[0], text)
          this.getUIContext().getPromptAction().showToast({ message: localizedText($r('app.string.text_profile_saved')) })
        }
      } else if (destination === 1) {
        await ConfigTransfer.shareBackup(context, title, text)
      }
    } catch (_) { this.message = localizedText($r('app.string.text_backup_configuration_failed_please_try_again')) }
    finally { this.saving = false }
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
    if (!/^\d+$/.test(value)) throw new Error(localizedText($r('app.string.text_the_duration_of_the_event_must_be')))
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
    if (!/^\d+$/.test(value)) throw new Error(localizedText($r('app.string.text_please_enter_the_full_number_of_days')))
    await TrashSettingsService.saveRetentionDays(this.getUIContext().getHostContext()!, Number(value))
    this.savedRetentionDays = Number(value)
  }
  private openHelp(article: string, anchor: string = ''): void {
    PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/Help', params: { article, anchor } })
  }

  @Builder
  taskReminderSettings() {
    SettingsGroup({ title: localizedText($r('app.string.text_task_reminders_on_this_device')), detail: this.reminderHelpDetail() }) {
      Row() {
        Text($r('app.string.text_enable_task_alarm')).fontSize(16).fontColor(UiColor.text).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.reminderEnabled }).id('reminder_global_enabled')
          .enabled(!this.calendarBusy)
          .onChange((value: boolean): void => { if (value !== this.reminderEnabled) this.changeReminder(value) })
      }.width('100%').padding(16)
      Text(this.reminderSummary).id('reminder_service_status').fontSize(13).fontColor(UiColor.secondary)
        .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 12 })
      Row({ space: 12 }) {
        Text($r('app.string.text_duration_of_events_minutes')).fontSize(16).fontColor(UiColor.text).layoutWeight(1)
        TextInput({ text: this.eventDurationDraft, placeholder: '5' }).type(InputType.Number).width(96)
          .id('reminder_event_duration').fontSize(16).fontColor(UiColor.text).backgroundColor(UiColor.field)
          .onChange((value: string): void => { if (value !== this.eventDurationDraft) this.changeEventDuration(value) })
          .onBlur((): void => { this.preferenceSave.flush() })
      }.width('100%').padding(16)
      SettingsRow({ title: localizedText($r('app.string.text_organisation_2')), value: this.calendarDetail(), action: (): void => { this.manageCalendar() } })
      SettingsRow({ title: localizedText($r('app.string.text_reminder_activity')), icon: $r('app.media.nav_logbook'),
        action: (): void => { this.openSection('提醒操作日志') } }).id('reminder_operation_entry')
      SettingsRow({ title: localizedText($r('app.string.help_reminder_article')), icon: $r('app.media.ui_info'), divider: false,
        action: (): void => { this.openHelp('help-reminder-help', 'registration') } })
    }
    SettingsGroup({ title: localizedText($r('app.string.reminder_task_list')), detail: localizedText($r('app.string.text_shares_the_same_task_data_set_with')) }) {
      TaskReminderList()
    }
  }
  @Builder
  trashSettings() {
    SettingsGroup({ title: localizedText($r('app.string.text_number_of_days_retained')), detail: localizedText($r('app.string.text_the_default_saves_30_days_setting_1')) }) {
      TextInput({ text: this.retentionDraft, placeholder: localizedText($r('app.string.text_number_of_days_retained')) }).type(InputType.Number)
        .id('trash_retention_days').onChange((value: string): void => { if (value !== this.retentionDraft) this.changeRetention(value) })
        .onBlur((): void => { this.preferenceSave.flush() })
    }
  }

  @Builder
  fileEntries() {
    SettingsGroup({ title: localizedText($r('app.string.text_entry_notebook')), detail: localizedText($r('app.string.text_when_you_select_a_notebook_the_records')) }) {
      SettingsRow({ title: localizedText($r('app.string.text_inbox')), value: this.fileTargetTitle('inbox'), detail: this.fileTargetDetail('inbox'), icon: $r('app.media.nav_inbox'), action: (): void => { this.openFilePicker('inbox') } })
      SettingsRow({ title: localizedText($r('app.string.text_someday')), value: this.fileTargetTitle('someday'), detail: this.fileTargetDetail('someday'), icon: $r('app.media.nav_someday'), action: (): void => { this.openFilePicker('someday') } })
      SettingsRow({ title: localizedText($r('app.string.text_notes')), value: this.fileTargetTitle('memo'), detail: this.fileTargetDetail('memo'), icon: $r('app.media.nav_memo'), action: (): void => { this.openFilePicker('memo') } })
      SettingsRow({ title: localizedText($r('app.string.help_file_entries_article')), icon: $r('app.media.ui_info'), divider: false,
        action: (): void => { this.openHelp('help-file-entries') } })
    }
  }

  @Builder
  appLinksSettings() {
    Column() {
      if (this.appLinkNames().length === 0) {
        EmptyState({ title: localizedText($r('app.string.text_no_connection_applied_yet')) }).id('app_link_empty')
      } else {
        Scroll() {
          Column() {
            Column() {
              ForEach(this.appLinkNames(), (name: string) => {
                this.appLinkRow(name, this.appLinkBundle(name))
              }, (name: string) => JSON.stringify([name, this.appLinkBundle(name)]))
            }.width('100%').backgroundColor(UiColor.container).borderRadius(12).clip(true)
          }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 32 })
        }.width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Off)
      }
    }.width('100%').layoutWeight(1)
  }

  @Builder
  appLinkRow(name: string, bundleName: string) {
    SettingsRow({ title: name, value: bundleName ? this.appLinkTargetLabel(bundleName) : localizedText($r('app.string.text_unbound')),
      appIcon: this.appLinkIcon(bundleName) ?? $r('app.media.ui_link_app'),
      action: (): void => { this.chooseAppLink(name) }, disabled: this.appLinkBusy })
  }

  @Builder
  appLinkPickerSheet() {
    Column() {
      Text($r('app.string.text_select_application')).fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
        .width('100%').padding({ left: 24, top: 8, bottom: 4 }).textAlign(TextAlign.Start)
      Text(this.appLinkPickerName).fontSize(14).fontColor(UiColor.secondary)
        .width('100%').padding({ left: 24, bottom: 10 }).textAlign(TextAlign.Start)
      if (this.appLinkPickerBusy) {
        EmptyState({ title: localizedText($r('app.string.text_reading_application_list')), busy: true })
      } else if (this.appLinkCandidateError && this.appLinkCandidates.length === 0) {
        EmptyState({ title: this.appLinkCandidateError, actionLabel: localizedText($r('app.string.text_retry')),
          action: (): void => { this.loadAppLinkCandidates() } })
      } else if (this.appLinkCandidates.length === 0) {
        EmptyState({ title: localizedText($r('app.string.text_no_application_available')) })
      } else {
        MessageBar({ message: this.appLinkCandidateError, error: true })
        Scroll() {
          Column() {
            ForEach(this.appLinkCandidates, (candidate: AppLinkCatalogEntry) => {
              Row({ space: 12 }) {
                Image(candidate.iconResource ?? (candidate.icon ? $rawfile(candidate.icon) : $r('app.media.ui_link_app')))
                  .width(36).height(36).objectFit(ImageFit.Contain)
                  .borderRadius(8).accessibilityLevel('no')
                Text(candidate.name).fontSize(17).fontColor(UiColor.text).layoutWeight(1)
                if (candidate.id === this.appLinkPickerBundle) {
                  Text($r('app.string.text_current_binding')).fontSize(13).fontColor(UiColor.primary)
                } else {
                  Image($r('app.media.ui_next')).width(24).height(24).fillColor(UiColor.primary).accessibilityLevel('no')
                }
              }.width('100%').padding({ left: 24, right: 24, top: 10, bottom: 10 })
                .accessibilityGroup(true)
                .accessibilityText(candidate.id === this.appLinkPickerBundle ? localizedText($r('app.string.text_current_binding_2'), String(candidate.name)) : localizedText($r('app.string.text_bind'), String(candidate.name)))
                .onClick((): void => { this.bindAppLink(candidate) })
            }, (candidate: AppLinkCatalogEntry) => candidate.id)
          }
        }.width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Off)
      }
      if (this.appLinkPickerBundle && !this.appLinkPickerBusy) {
        Row() {
          Button($r('app.string.text_untie')).height(44).fontSize(14).fontColor(UiColor.secondary).backgroundColor(Color.Transparent)
            .enabled(!this.appLinkBusy).onClick((): void => { this.deleteAppLink(this.appLinkPickerName) })
        }.width('100%').justifyContent(FlexAlign.End).padding({ left: 24, right: 24, bottom: 8 })
      }
    }.width('100%').height('100%').backgroundColor(UiColor.surface).borderRadius({ topLeft: 28, topRight: 28 })
  }

  @Builder
  categories() {
    SettingsGroup({ title: localizedText($r('app.string.text_status_classification')), detail: localizedText($r('app.string.text_default_status_fixes_custom_state_with_x')) }) {
      ForEach(this.stateCategories, (category: TaskStateCategory, index: number) => {
        Column({ space: 8 }) {
          Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
            space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(4) } }) {
            Text(taskStateCategoryLabel(category)).fontSize(16).fontColor(UiColor.text)
            ForEach(this.categoryStates(index, true), (state: CoreTaskState) => {
              Text(state.name).fontFamily('monospace').fontSize(13).fontColor(UiColor.text)
                .padding({ left: 8, right: 8, top: 5, bottom: 5 }).borderRadius(6)
                .border({ width: 0.5, color: UiColor.outline }).accessibilityText(localizedText($r('app.string.text_default_read_only'), String(state.name)))
            }, (state: CoreTaskState) => state.name)
            ForEach(this.categoryStates(index, false), (state: CoreTaskState) => {
              Button(`${state.name}  ×`).fontSize(13).fontFamily('monospace').height(32).borderRadius(6)
                .padding({ left: 8, right: 8 }).constraintSize({ maxWidth: '100%' })
                .fontColor(UiColor.text).backgroundColor(UiColor.field).accessibilityText(localizedText($r('app.string.text_remove_custom_status'), String(state.name)))
                .onClick((): void => { this.changeCategory(index, state.name) })
            }, (state: CoreTaskState) => state.name)
            Button('+').fontSize(22).width(36).height(36).padding(0)
              .backgroundColor(Color.Transparent).fontColor(UiColor.primary)
              .accessibilityText(localizedText($r('app.string.text_add_status_to'), String(taskStateCategoryLabel(category))))
              .onClick((): void => { this.editingCategory = index; this.categoryDraft = ''; this.message = '' })
          }.width('100%')
          if (this.editingCategory === index) {
            Row({ space: 8 }) {
              TextInput({ text: this.categoryDraft, placeholder: localizedText($r('app.string.text_enter_status_value')) }).layoutWeight(1).height(44)
                .backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary)
                .onChange((value: string): void => { this.categoryDraft = value })
              Button($r('app.string.text_add_2')).height(44).fontSize(14).backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary)
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
    SettingsGroup({ title: localizedText($r('app.string.text_configured_repository')), detail: localizedText($r('app.string.text_manages_local_file_directories_and_webdav_connections')) }) {
      if (this.config.repos.filter(repo => !isSystemRepository(repo)).length === 0) {
        Text($r('app.string.text_the_repository_has_not_been_configured')).fontSize(14).fontColor(UiColor.secondary).width('100%').padding(16)
      }
      ForEach(this.config.repos.filter(repo => !isSystemRepository(repo)), (repo: RepoConfig) => {
        SettingsRow({ title: repositoryLabel(repo), value: repo.webdavEnabled ? 'WebDAV' : localizedText($r('app.string.text_do_not_sync')), detail: repo.rootDirectory,
          icon: $r('app.media.nav_repository'),
          action: (): void => { PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/RepositorySettings', params: { repoId: repo.id } }) } })
      }, (repo: RepoConfig) => repo.id)
      SettingsRow({ title: localizedText($r('app.string.text_add_repository')), icon: $r('app.media.ui_add'), divider: false,
        action: (): void => { addRepository(this.getUIContext()) } })
    }
  }

  build() {
    Column() {
      AppShell({ title: this.sectionTitle(), activeRoute: 'pages/Settings', drawerOpen: $drawerOpen,
        back: this.section.length > 0 || PageNavigator.shared.path.depth > 1, busy: this.saving || this.categoryBusy || this.filePickerBusy || this.appLinkBusy || this.appLinkPickerBusy,
        actionLabel: this.loaded && !this.section ? localizedText($r('app.string.text_more_2')) : '', actionMenuItems: this.settingsMenu(),
        backAction: (): void => { this.onBackPress() }, titleIcon: $r('app.media.nav_settings') }) {
        Column() {
          MessageBar({ message: this.message, error: true })
          if (this.loaded && this.section === '应用关联') {
            this.appLinksSettings()
          } else {
            Scroll() {
              Column() {
                if (!this.loaded && this.message) {
                  Button($r('app.string.text_reread_settings')).height(44).backgroundColor(UiColor.selected).fontColor(UiColor.onSelected).margin(24)
                    .onClick((): void => { this.message = ''; this.load() })
                } else if (!this.loaded) {
                  LoadingProgress().width(32).height(32).color(UiColor.primary).margin(24)
                } else if (!this.section) { this.homepage() }
                else if (this.section === '任务提醒') { this.taskReminderSettings() }
                else if (this.section === '提醒操作日志') {
                  SettingsGroup({ title: localizedText($r('app.string.text_current_run')), detail: localizedText($r('app.string.text_displays_the_new_modified_and_deleted_records')) }) {
                    ReminderOperationList()
                  }
                }
                else if (this.section === '废纸篓') { this.trashSettings() }
                else if (this.section === '文件入口') { this.fileEntries() }
                else if (this.section === '任务状态分类') { this.categories() }
                else if (this.section === '存储库') { this.repositories() }
                else {
                  SettingsGroup({ title: localizedText($r('app.string.EntryAbility_label')) }) {
                    Text($r('app.string.text_browse_the_org_notebook_view_the_tasks'))
                      .fontSize(16).fontColor(UiColor.secondary).lineHeight(26).width('100%').padding(16)
                  }
                }
              }.width('100%').padding({ left: 16, right: 16, bottom: 32 }).enabled(!this.saving && !this.categoryBusy)
            }.width('100%').layoutWeight(1).align(Alignment.TopStart)
          }
        }.width('100%').height('100%')
          .bindSheet($$this.appLinkPickerOpen, this.appLinkPickerSheet, {
            height: '55%', detents: ['55%', '85%'], preferType: SheetType.BOTTOM,
            backgroundColor: UiColor.container, showClose: true,
            onWillDismiss: (): void => { if (!this.appLinkBusy && !this.appLinkPickerBusy) this.appLinkPickerOpen = false }
          })
      }
    }.width('100%').height('100%')
      .bindSheet($$this.filePickerOpen, this.filePicker, {
        height: '70%', detents: ['70%', '90%'], preferType: SheetType.BOTTOM,
        backgroundColor: UiColor.container, showClose: true,
        onWillDismiss: (action): void => { if (!this.filePickerBusy) action.dismiss() }
      })
  }
}
