import { Context, common } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { fileIo, fileUri } from '@kit.CoreFileKit'
import { systemShare } from '@kit.ShareKit'
import { preferences } from '@kit.ArkData'
import { decodeConfigurationYaml, encodeConfigurationYaml, defaultTodoSettings, defaultSyncOptions,
  validateConfiguration, normalizeSyncOptions,
  CoreSettings } from 'liborg_tasks_harmony.so'
import { AppConfig, AppLinkAssociation, DEFAULT_CONFIG, RepoConfig } from '../models/OrgTask'
import { isSystemRepository, SYSTEM_REPOSITORY_ID } from '../models/SystemRepository'
import { AppConfigService, validateEntryFile } from './AppConfigService'
import { localDate, repositoryLabel } from '../ui/Theme'
import { RegionOrder } from '../ui/RegionOrderPresentation'
import { REGION_ORDER_KEY, RegionOrderService, validRegionOrder } from './RegionOrderService'
import { APP_LINK_ASSOCIATIONS_KEY, AppLinkManager } from './AppLinkService'
import { DEFAULT_TRASH_RETENTION_DAYS, TRASH_RETENTION_KEY, TrashSettingsService } from './TrashSettingsService'
import { TaskReminderConfiguration, TaskReminderSettings } from './TaskReminderSettings'
import { DEFAULT_EVENT_DURATION_MINUTES } from './CalendarEventProjection'
import { ReminderManager } from './ReminderManager'
import { CredentialService } from './CredentialService'
import { NativeCoreService } from './NativeCoreService'
import { RepositorySyncService } from './RepositorySyncService'

const FORMAT = 'org-tasks-config'
const VERSION = 1
const MAX_BYTES = 64 * 1024
export const CONFIG_FILE_EXTENSION = '.orgtasks'


export interface TransferRepository {
  id: string
  name: string
  rootDirectory: string
  webdavEnabled: boolean
  webdavUrl: string
  webdavUsername: string
  excludedDirectories: string[]
}

interface TransferSettings {
  repos: TransferRepository[]
  inboxFile: string
  inboxRepoId: string
  somedayFile: string
  somedayRepoId: string
  memoFile: string
  memoRepoId: string
  calendarName: string
  todoDefaults: string
  coreSettings: CoreSettings
  fileDisplayMode: 'rendered' | 'source'
  preferences?: BackupPreferences
}

interface BackupPreferences {
  reminders: TaskReminderConfiguration
  trashRetentionDays: number
  appLinkAssociations: AppLinkAssociation[]
  regionOrder: RegionOrder | null
}

export interface ConfigDocument {
  format: string
  version: number
  settings: TransferSettings
}

export interface ConfigImportPreview {
  document: ConfigDocument
  warnings: string[]
}

interface ImportPlan {
  config: AppConfig
  warnings: string[]
}

function checkSize(text: string): void {
  if (text.length > MAX_BYTES || util.TextEncoder.create().encodeInto(text).length > MAX_BYTES) {
    throw new Error('配置文件不能超过 64 KB')
  }
}

function looksLikeConfiguration(text: string): boolean {
  return /^\uFEFF?(?:format|"format"|'format')[ \t]*:[ \t]*(?:org-tasks-config|"org-tasks-config"|'org-tasks-config')[ \t]*(?:#[^\r\n]*)?\r?$/m.test(text)
}

async function decodeConfiguration(text: string): Promise<ConfigDocument> {
  checkSize(text)
  if (!looksLikeConfiguration(text)) throw new Error('未识别到小清单 YAML 配置')
  const doc = await decodeConfigurationYaml(text) as ConfigDocument
  if (!doc || doc.format !== FORMAT) throw new Error('未识别到小清单配置')
  if (doc.version !== VERSION) throw new Error('此版本的小清单无法读取该配置版本')
  const settings = doc.settings
  if (!settings || !Array.isArray(settings.repos) ||
    ![settings.inboxFile, settings.inboxRepoId, settings.somedayFile, settings.somedayRepoId,
      settings.memoFile, settings.memoRepoId, settings.calendarName, settings.todoDefaults]
      .every((value: string): boolean => typeof value === 'string') ||
    (settings.fileDisplayMode !== 'rendered' && settings.fileDisplayMode !== 'source') ||
    !Array.isArray(settings.coreSettings?.additionStates) ||
    settings.coreSettings.additionStates.some(state => !state || typeof state.name !== 'string' ||
      (state.category !== null && !['Todo', 'Doing', 'Wait', 'Done', 'Cancel'].includes(state.category)))) {
    throw new Error('设置字段缺失或类型有误')
  }
  const ids = new Set<string>()
  const roots = new Set<string>()
  for (const repo of settings.repos) {
    if (!repo || ![repo.id, repo.name, repo.rootDirectory, repo.webdavUrl, repo.webdavUsername]
      .every((value: string): boolean => typeof value === 'string') ||
      typeof repo.webdavEnabled !== 'boolean' || !Array.isArray(repo.excludedDirectories) ||
      !repo.excludedDirectories.every((value: string): boolean => typeof value === 'string')) {
      throw new Error('存储库字段缺失或类型有误')
    }
    repo.rootDirectory = normalizedRoot(repo.rootDirectory)
    repo.webdavUrl = repo.webdavUrl.trim()
    repo.webdavUsername = repo.webdavUsername.trim()
    if (!repo.id.trim() || repo.id === SYSTEM_REPOSITORY_ID || ids.has(repo.id) || roots.has(repo.rootDirectory)) {
      throw new Error('配置中的存储库标识和目录必须有效且唯一')
    }
    if ((repo.webdavUrl || repo.webdavEnabled) && !shareableWebDavUrl(repo.webdavUrl) ||
      (repo.webdavEnabled && !repo.webdavUsername)) {
      throw new Error('WebDAV 配置需要 HTTPS 目录地址和有效账号')
    }
    ids.add(repo.id)
    roots.add(repo.rootDirectory)
  }
  validateTarget(settings.inboxFile, settings.inboxRepoId, '收件箱', ids)
  validateTarget(settings.somedayFile, settings.somedayRepoId, '某天', ids)
  validateTarget(settings.memoFile, settings.memoRepoId, '备忘', ids)
  const prefs = settings.preferences
  if (prefs !== undefined && (!prefs || typeof prefs.reminders?.enabled !== 'boolean' ||
    !Number.isInteger(prefs.reminders.eventDurationMinutes) ||
    prefs.reminders.eventDurationMinutes < 1 || prefs.reminders.eventDurationMinutes > 1440 ||
    !Number.isInteger(prefs.trashRetentionDays) || prefs.trashRetentionDays < 1 || prefs.trashRetentionDays > 3650 ||
    !Array.isArray(prefs.appLinkAssociations) || prefs.appLinkAssociations.some(item =>
      !item || typeof item.name !== 'string' || !item.name.trim() ||
      typeof item.bundleName !== 'string' || !item.bundleName.trim()) ||
    (prefs.regionOrder !== null && !validRegionOrder(prefs.regionOrder)))) {
    throw new Error('备份中的应用偏好设置无效')
  }
  return doc
}

function validateTarget(path: string, id: string, name: string, ids: Set<string>): void {
  validateEntryFile(path)
  if ((path.trim() || id) && (!path.trim() || !ids.has(id))) {
    throw new Error(name + '必须引用配置中的存储库和文件')
  }
}

function normalizedRoot(path: string): string {
  const trimmed = path.trim()
  const components = trimmed.split('/').filter((part: string): boolean => part.length > 0 && part !== '.')
  if (!trimmed.startsWith('/') || components.length === 0 || components.includes('..') || /[\x00-\x1f\x7f]/.test(trimmed)) {
    throw new Error('存储库目录必须是本机绝对路径')
  }
  return '/' + components.join('/')
}

function shareableWebDavUrl(url: string): boolean {
  return /^https:\/\/[^/?#@\\\s]+(?:\/[^?#\\\s]*)?$/.test(url)
}

function exportRepository(repo: RepoConfig): TransferRepository {
  const url = shareableWebDavUrl(repo.webdavUrl) ? repo.webdavUrl : ''
  return { id: repo.id, name: repo.name, rootDirectory: repo.rootDirectory,
    webdavEnabled: repo.webdavEnabled && !!url && !!repo.webdavUsername, webdavUrl: url,
    webdavUsername: repo.webdavUsername, excludedDirectories: repo.excludedDirectories }
}

export class ConfigTransfer {
  static async exportText(context: Context): Promise<string> {
    const config = await AppConfigService.load(context, false)
    const repos = config.repos.filter(repo => !isSystemRepository(repo)).map(exportRepository)
    const prefs: BackupPreferences = {
      reminders: await TaskReminderSettings.load(context),
      trashRetentionDays: await TrashSettingsService.retentionDays(context),
      appLinkAssociations: await AppLinkManager.shared.load(context, true),
      regionOrder: await RegionOrderService.load(context)
    }
    const document: ConfigDocument = { format: FORMAT, version: VERSION, settings: {
      repos, inboxFile: config.inboxFile, inboxRepoId: config.inboxRepoId,
      somedayFile: config.somedayFile, somedayRepoId: config.somedayRepoId,
      memoFile: config.memoFile, memoRepoId: config.memoRepoId, calendarName: config.calendarName,
      todoDefaults: config.todoDefaults, coreSettings: config.coreSettings, fileDisplayMode: config.fileDisplayMode,
      preferences: prefs
    } }
    const encoded = await encodeConfigurationYaml(document)
    checkSize(encoded)
    return encoded
  }

  static async preview(context: Context, text: string): Promise<ConfigImportPreview> {
    const document = await decodeConfiguration(text)
    const current = await AppConfigService.load(context, false)
    const plan = await ConfigTransfer.plan(current, document)
    return { document, warnings: plan.warnings }
  }

  static apply(context: Context, preview: ConfigImportPreview): Promise<void> {
    return ConfigTransfer.writeConfiguration(context, preview.document.settings.preferences, async (current: AppConfig): Promise<AppConfig> => {
      const plan = await ConfigTransfer.plan(current, preview.document)
      if (JSON.stringify(plan.warnings) !== JSON.stringify(preview.warnings)) {
        throw new Error('本机配置或目录发生变化，请重新预览')
      }
      return plan.config
    })
  }

  static reset(context: Context): Promise<void> {
    const defaults: BackupPreferences = {
      reminders: { enabled: false, eventDurationMinutes: DEFAULT_EVENT_DURATION_MINUTES },
      trashRetentionDays: DEFAULT_TRASH_RETENTION_DAYS, appLinkAssociations: [], regionOrder: null
    }
    return ConfigTransfer.writeConfiguration(context, defaults, async (current: AppConfig): Promise<AppConfig> => {
      const syncDefaults = await defaultSyncOptions()
      const todoDefaults = await defaultTodoSettings()
      const repos = current.repos.map((repo: RepoConfig): RepoConfig => {
        if (isSystemRepository(repo)) return repo
        return { id: repo.id, rootDirectory: repo.rootDirectory, name: '', webdavEnabled: false,
          webdavUrl: '', webdavUsername: '', webdavPassword: '', excludedDirectories: syncDefaults.excludedDirectories.slice() }
      })
      // 释放进程中的远端凭据，保留用于恢复的同步记录和待上传数据。
      if (current.repos.some(repo => repo.webdavEnabled || repo.webdavCleanupPending)) {
        await NativeCoreService.workspaceFor(current.repos.filter(repo => !repo.webdavEnabled && !repo.webdavCleanupPending),
          current.todoDefaults, current.coreSettings)
      }
      return { repos, todoDefaults, coreSettings: DEFAULT_CONFIG.coreSettings,
        inboxFile: '', inboxRepoId: '', somedayFile: '', somedayRepoId: '', memoFile: '', memoRepoId: '',
        calendarName: DEFAULT_CONFIG.calendarName, fileDisplayMode: DEFAULT_CONFIG.fileDisplayMode }
    }, true)
  }

  private static writeConfiguration(context: Context, prefs: BackupPreferences | undefined,
    configuration: (current: AppConfig) => Promise<AppConfig>, reset: boolean = false): Promise<void> {
    return RepositorySyncService.changeConfiguration(async (): Promise<void> => {
      const values = new Map<string, preferences.ValueType | undefined>()
      let previousReminder: TaskReminderConfiguration | undefined
      if (prefs) {
        values.set(TRASH_RETENTION_KEY, reset ? undefined : prefs.trashRetentionDays)
        values.set(APP_LINK_ASSOCIATIONS_KEY, prefs.appLinkAssociations.length ? JSON.stringify(prefs.appLinkAssociations) : undefined)
        values.set(REGION_ORDER_KEY, prefs.regionOrder ? JSON.stringify(prefs.regionOrder) : undefined)
        previousReminder = await TaskReminderSettings.load(context)
        await TaskReminderSettings.save(context, { enabled: prefs.reminders.enabled,
          eventDurationMinutes: prefs.reminders.eventDurationMinutes })
      }
      try {
        await AppConfigService.restore(context, configuration, values, reset)
      } catch (error) {
        if (previousReminder) await TaskReminderSettings.save(context, { enabled: previousReminder.enabled,
          eventDurationMinutes: previousReminder.eventDurationMinutes })
        if (reset) {
          const current = await AppConfigService.load(context, false)
          await NativeCoreService.workspaceFor(current.repos, current.todoDefaults, current.coreSettings)
        }
        throw error as Error
      }
      if (prefs) {
        AppLinkManager.shared.invalidateAssociations()
        RegionOrderService.publish(prefs.regionOrder)
        await ReminderManager.refresh('设置变更')
      }
    })
  }

  private static async plan(current: AppConfig, document: ConfigDocument): Promise<ImportPlan> {
    const settings = document.settings
    const coreSettings = await validateConfiguration({ todoDefaults: settings.todoDefaults, coreSettings: settings.coreSettings })
    const repoIds = new Map<string, string>()
    const warnings: string[] = []
    const repos = current.repos.slice()
    for (const imported of settings.repos) {
      const existing = repos.find(repo => repo.rootDirectory.replace(/\/+$/, '') === imported.rootDirectory)
      if (existing && isSystemRepository(existing)) throw new Error('系统存储库由应用管理')
      if (existing?.webdavCleanupPending) throw new Error('请先完成“' + repositoryLabel(existing) + '”的同步信息清理')
      const sameAccount = existing?.webdavUrl === imported.webdavUrl && existing?.webdavUsername === imported.webdavUsername
      if (existing && ((existing.webdavEnabled && !imported.webdavEnabled) ||
        ((existing.webdavEnabled || existing.webdavUsername) && !sameAccount))) {
        throw new Error('请先在存储库设置中处理“' + repositoryLabel(existing) + '”的 WebDAV 连接变更')
      }
      const options = await normalizeSyncOptions({ excludedDirectories: imported.excludedDirectories })
      const repo = existing ?? AppConfigService.newRepository(imported.rootDirectory)
      const restored: RepoConfig = {
        id: repo.id, name: imported.name, rootDirectory: repo.rootDirectory,
        webdavEnabled: repo.webdavEnabled, webdavUrl: imported.webdavUrl, webdavUsername: imported.webdavUsername,
        webdavPassword: '', excludedDirectories: options.excludedDirectories
      }
      if (existing?.id === imported.id && !existing.webdavUrl && imported.webdavUrl) {
        restored.webdavPassword = await CredentialService.passwordForRestore(restored)
        restored.webdavEnabled = imported.webdavEnabled && !!restored.webdavPassword
      }
      repoIds.set(imported.id, repo.id)
      if (existing) repos[repos.indexOf(existing)] = restored
      else repos.push(restored)
      if (imported.webdavEnabled && !restored.webdavEnabled) {
        warnings.push('“' + repositoryLabel(restored) + '”需要在存储库设置中填写密码并启用 WebDAV。')
      }
      try {
        if (!(await fileIo.stat(restored.rootDirectory)).isDirectory()) throw new Error()
      } catch (_) {
        warnings.push('“' + repositoryLabel(restored) + '”的本地目录不可用，请在存储库设置中重新选择。')
      }
    }
    const config: AppConfig = {
      repos, coreSettings, inboxFile: settings.inboxFile, inboxRepoId: repoIds.get(settings.inboxRepoId) ?? '',
      somedayFile: settings.somedayFile, somedayRepoId: repoIds.get(settings.somedayRepoId) ?? '',
      memoFile: settings.memoFile, memoRepoId: repoIds.get(settings.memoRepoId) ?? '',
      calendarName: settings.calendarName, todoDefaults: settings.todoDefaults, fileDisplayMode: settings.fileDisplayMode
    }
    return { config, warnings }
  }

  static async readFile(uri: string): Promise<string> {
    let file: fileIo.File | undefined
    try {
      file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY)
      const stat = await fileIo.stat(file.fd)
      if (!stat.isFile() || stat.size > MAX_BYTES) throw new Error('请选择 64 KB 以内的配置文本文件')
      const bytes = new Uint8Array(MAX_BYTES + 1)
      let offset = 0
      while (offset < bytes.byteLength) {
        const chunk = new ArrayBuffer(bytes.byteLength - offset)
        const read = await fileIo.read(file.fd, chunk)
        if (read === 0) break
        bytes.set(new Uint8Array(chunk, 0, read), offset)
        offset += read
      }
      if (offset > MAX_BYTES) throw new Error('配置文件不能超过 64 KB')
      return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes.subarray(0, offset))
    } catch (_) {
      throw new Error('请选择 64 KB 以内的 UTF-8 配置文本文件')
    } finally {
      if (file) {
        try { await fileIo.close(file) }
        catch (_) { throw new Error('关闭配置文件失败') }
      }
    }
  }

  static async writeFile(uri: string, text: string): Promise<void> {
    const buffer = util.TextEncoder.create().encodeInto(text).buffer
    let file: fileIo.File | undefined
    try {
      file = await fileIo.open(uri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC)
      let offset = 0
      while (offset < buffer.byteLength) {
        const written = await fileIo.write(file.fd, buffer.slice(offset))
        if (written <= 0) throw new Error('写入配置文件失败')
        offset += written
      }
    } catch (_) {
      throw new Error('写入配置文件失败')
    } finally {
      if (file) {
        try { await fileIo.close(file) }
        catch (_) { throw new Error('关闭配置文件失败') }
      }
    }
  }

  static async shareBackup(context: common.UIAbilityContext, title: string, text: string): Promise<void> {
    try {
      const directory = await fileIo.mkdtemp(context.cacheDir + '/org-tasks-config-XXXXXX')
      const path = directory + '/' + title + CONFIG_FILE_EXTENSION
      await ConfigTransfer.writeFile(path, text)
      const data = new systemShare.SharedData({ utd: 'general.file', title, uri: fileUri.getUriFromPath(path) })
      const controller = new systemShare.ShareController(data)
      await controller.show(context, { selectionMode: systemShare.SelectionMode.SINGLE })
    } catch (_) { throw new Error('打开系统分享失败') }
  }

  static backupTitle(date: Date = new Date()): string {
    const time = [date.getHours(), date.getMinutes(), date.getSeconds()]
      .map((value: number): string => value.toString().padStart(2, '0')).join('-')
    return '小清单配置-' + localDate(date) + '_' + time
  }
}
