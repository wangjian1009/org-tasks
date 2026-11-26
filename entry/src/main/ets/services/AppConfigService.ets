import { localizedText } from '../ui/LocalizedText'
// 集中读取应用配置；配置 ID 用于定位配置和凭据，core 仓库 ID 由目录维护。

import { defaultSyncOptions, normalizeSyncOptions, defaultTodoSettings, SyncOptions as NativeSyncOptions, CoreSettings, validateConfiguration } from 'liborg_tasks_harmony.so'
import { Context } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { util } from '@kit.ArkTS'
import { PreferencesStore } from './PreferencesStore'
import { AppConfig, DEFAULT_CONFIG, RepoConfig, SyncOptions } from '../models/OrgTask'
import { CredentialService } from './CredentialService'
import { SystemRepositoryService } from './SystemRepositoryService'

export const APP_CONFIG_PREFERENCES = 'org_tasks_config'
const REPOS_KEY = 'repos'

export function validateEntryFile(path: string): void {
  const file = path.trim()
  if (file && (!file.endsWith('.org') || file.startsWith('/') || file.includes('\\') ||
    file.split('/').some((part: string) => part === '..' || part === '.' || part.length === 0) ||
    file.split('/')[0] === '.sync' || /[\x00-\x1f\x7f]/.test(file))) {
    throw new Error(localizedText($r('app.string.text_inboxes_one_day_and_memo_files_must')))
  }
}

export class AppConfigService {
  private static changeListeners: Set<() => void> = new Set()
  private static pendingSave: Promise<void> = Promise.resolve()

  static watchChanges(listener: () => void): void { AppConfigService.changeListeners.add(listener) }
  static stopWatchingChanges(listener: () => void): void { AppConfigService.changeListeners.delete(listener) }

  static async hasUserRepositories(context: Context): Promise<boolean> {
    const store = await PreferencesStore.open(context, APP_CONFIG_PREFERENCES)
    const repos = await AppConfigService.loadRepositories(store, false)
    return repos.some(repo => !SystemRepositoryService.isSystem(repo))
  }

  static async load(context: Context, includeCredentials: boolean = true): Promise<AppConfig> {
    const store = await PreferencesStore.open(context, APP_CONFIG_PREFERENCES)
    const repos = (await AppConfigService.loadRepositories(store, includeCredentials)).filter(repo => !SystemRepositoryService.isSystem(repo))
    repos.push(await SystemRepositoryService.ensure(context))
    const inboxFile = await store.get('inboxFile', DEFAULT_CONFIG.inboxFile) as string
    const inboxRepoId = await store.get('inboxRepoId', DEFAULT_CONFIG.inboxRepoId) as string
    const somedayFile = await store.get('somedayFile', DEFAULT_CONFIG.somedayFile) as string
    const somedayRepoId = await store.get('somedayRepoId', DEFAULT_CONFIG.somedayRepoId) as string
    const memoFile = await store.get('memoFile', DEFAULT_CONFIG.memoFile) as string
    const memoRepoId = await store.get('memoRepoId', DEFAULT_CONFIG.memoRepoId) as string
    const calendarName = await store.get('calendarName', DEFAULT_CONFIG.calendarName) as string
    const todoDefaults = await store.has('todoDefaults')
      ? await store.get('todoDefaults', '') as string : await defaultTodoSettings()
    const savedCoreSettings = await store.get('coreSettings', '') as string
    let coreSettings: CoreSettings = savedCoreSettings ? JSON.parse(savedCoreSettings) as CoreSettings : await validateConfiguration({})
    // 旧分类拼写交给 Core 的兼容反序列化处理，设置界面与后续保存只接收规范名称。
    if (savedCoreSettings.includes('"Cancle"')) {
      coreSettings = await validateConfiguration({ coreSettings })
    }
    const fileDisplayMode = await store.get('fileDisplayMode', DEFAULT_CONFIG.fileDisplayMode) as string
    return {
      repos,
      inboxFile,
      inboxRepoId,
      somedayFile,
      somedayRepoId,
      memoFile,
      memoRepoId,
      calendarName,
      todoDefaults,
      coreSettings,
      fileDisplayMode: fileDisplayMode === 'source' ? 'source' : 'rendered'
    }
  }

  static save(context: Context, config: AppConfig): Promise<void> {
    return AppConfigService.enqueueSave(() => AppConfigService.persist(context, config, true))
  }

  static updateRepositories(context: Context, update: (current: AppConfig) => Promise<boolean>,
    removedRepoIds: string[] = []): Promise<void> {
    return AppConfigService.enqueueSave(async (): Promise<void> => {
      const current = await AppConfigService.load(context, false)
      if (await update(current)) await AppConfigService.persist(context, current, false, undefined, removedRepoIds)
    })
  }

  static restore(context: Context, merge: (current: AppConfig) => Promise<AppConfig>,
    preferencesToRestore?: Map<string, preferences.ValueType | undefined>, reset: boolean = false): Promise<void> {
    return AppConfigService.enqueueSave(async (): Promise<void> => {
      const current = await AppConfigService.load(context, false)
      const removedRepos = reset ? current.repos.filter(repo => !SystemRepositoryService.isSystem(repo)) : []
      for (const repo of removedRepos) await CredentialService.preserveForReset(repo)
      await AppConfigService.persist(context, await merge(current), false, preferencesToRestore,
        removedRepos.map(repo => repo.id))
    })
  }

  static renameFileTargets(context: Context, repoId: string, oldPath: string, newPath: string): Promise<void> {
    return AppConfigService.enqueueSave(async (): Promise<void> => {
      const config = await AppConfigService.load(context, false)
      const inbox = config.inboxRepoId === repoId && config.inboxFile === oldPath
      const someday = config.somedayRepoId === repoId && config.somedayFile === oldPath
      const memo = config.memoRepoId === repoId && config.memoFile === oldPath
      if (inbox) config.inboxFile = newPath
      if (someday) config.somedayFile = newPath
      if (memo) config.memoFile = newPath
      if (inbox || someday || memo) await AppConfigService.persist(context, config, false)
    })
  }

  private static enqueueSave(save: () => Promise<void>): Promise<void> {
    const pending = AppConfigService.pendingSave.then(save)
    AppConfigService.pendingSave = pending.catch((): void => {})
    return pending
  }

  private static async persist(context: Context, config: AppConfig, writeCredentials: boolean,
    additional?: Map<string, preferences.ValueType | undefined>, removedRepoIds: string[] = []): Promise<void> {
    for (const file of [config.inboxFile, config.somedayFile, config.memoFile]) {
      validateEntryFile(file)
    }
    const coreSettings = await validateConfiguration({ todoDefaults: config.todoDefaults, coreSettings: config.coreSettings })
    const store = await PreferencesStore.open(context, APP_CONFIG_PREFERENCES)
    const persisted: RepoConfig[] = []
    for (const repository of config.repos) {
      if (SystemRepositoryService.isSystem(repository)) continue
      await normalizeSyncOptions({ excludedDirectories: repository.excludedDirectories } as SyncOptions)
    }
    for (const repository of config.repos) {
      if (SystemRepositoryService.isSystem(repository)) continue
      if (writeCredentials) await CredentialService.setWebDavPassword(repository.id, repository.webdavPassword)
      persisted.push({
        id: repository.id,
        name: (repository.name || '').trim(),
        rootDirectory: repository.rootDirectory.trim(),
        webdavEnabled: repository.webdavEnabled,
        webdavUrl: repository.webdavUrl.trim(),
        webdavUsername: repository.webdavUsername.trim(),
        webdavPassword: '',
        webdavCleanupPending: repository.webdavCleanupPending || undefined,
        excludedDirectories: repository.excludedDirectories || []
      })
    }
    const values = new Map<string, preferences.ValueType | undefined>([
      [REPOS_KEY, JSON.stringify(persisted)],
      ['inboxFile', config.inboxFile.trim()], ['inboxRepoId', config.inboxRepoId],
      ['somedayFile', config.somedayFile.trim()], ['somedayRepoId', config.somedayRepoId],
      ['memoFile', config.memoFile.trim()], ['memoRepoId', config.memoRepoId],
      ['calendarName', config.calendarName.trim()], ['todoDefaults', config.todoDefaults],
      ['coreSettings', JSON.stringify(coreSettings)], ['fileDisplayMode', config.fileDisplayMode]
    ])
    additional?.forEach((value, key): void => { values.set(key, value) })
    const previous = new Map<string, preferences.ValueType | undefined>()
    const previousPasswords = new Map<string, string>()
    if (!writeCredentials) {
      for (const key of values.keys()) {
        previous.set(key, await store.has(key) ? await store.get(key, '') : undefined)
      }
    }
    try {
      if (!writeCredentials) {
        const credentials = new Map<string, string>()
        for (const id of removedRepoIds) credentials.set(id, '')
        for (const repo of config.repos) {
          if (!SystemRepositoryService.isSystem(repo) && repo.webdavPassword) {
            credentials.set(repo.id, repo.webdavPassword)
          }
        }
        for (const entry of credentials) {
          previousPasswords.set(entry[0], await CredentialService.getWebDavPassword(entry[0]))
          await CredentialService.setWebDavPassword(entry[0], entry[1])
        }
      }
      for (const entry of values) {
        if (entry[1] === undefined) await store.delete(entry[0])
        else await store.put(entry[0], entry[1])
      }
      await store.flush()
    } catch (error) {
      for (const entry of previous) {
        const value = entry[1]
        if (value === undefined) await store.delete(entry[0])
        else await store.put(entry[0], value)
      }
      if (previous.size > 0) await store.flush()
      for (const entry of previousPasswords) await CredentialService.setWebDavPassword(entry[0], entry[1])
      throw error as Error
    }
    AppConfigService.changeListeners.forEach((listener: () => void): void => { listener() })
  }

  static async removeRepository(context: Context, configId: string, check?: (current: AppConfig) => void): Promise<void> {
    if (configId === 'org-tasks-system') throw new Error(localizedText($r('app.string.text_system_repository_cannot_be_deleted')))
    await AppConfigService.updateRepositories(context, async (current): Promise<boolean> => {
      check?.(current)
      current.repos = current.repos.filter((repo: RepoConfig) => repo.id !== configId)
      if (current.inboxRepoId === configId) { current.inboxRepoId = ''; current.inboxFile = '' }
      if (current.somedayRepoId === configId) { current.somedayRepoId = ''; current.somedayFile = '' }
      if (current.memoRepoId === configId) { current.memoRepoId = ''; current.memoFile = '' }
      return true
    }, [configId])
    await CredentialService.clearWebDavPassword(configId)
  }

  static newRepository(rootDirectory: string = ''): RepoConfig {
    return {
      id: util.generateRandomUUID(),
      name: '',
      rootDirectory,
      webdavEnabled: false,
      webdavUrl: '',
      webdavUsername: '',
      webdavPassword: '',
      excludedDirectories: []
    }
  }

  private static async loadRepositories(store: PreferencesStore, includeCredentials: boolean): Promise<RepoConfig[]> {
    const encoded = await store.get(REPOS_KEY, '') as string
    if (encoded.length > 0) {
      const persisted = JSON.parse(encoded) as RepoConfig[]
      const repositories: RepoConfig[] = []
      const defaults: NativeSyncOptions | undefined = persisted.some(repository => repository.excludedDirectories === undefined || repository.excludedDirectories === null)
        ? await defaultSyncOptions() : undefined
      for (const repository of persisted) {
        repositories.push({
          id: repository.id,
          name: repository.name || '',
          rootDirectory: repository.rootDirectory,
          webdavEnabled: repository.webdavEnabled,
          webdavUrl: repository.webdavUrl,
          webdavUsername: repository.webdavUsername,
          webdavPassword: includeCredentials ? await CredentialService.getWebDavPassword(repository.id) : '',
          webdavCleanupPending: repository.webdavCleanupPending || undefined,
          excludedDirectories: repository.excludedDirectories ?? defaults!.excludedDirectories.slice()
        })
      }
      return repositories
    }

    return []
  }
}
