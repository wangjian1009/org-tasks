// 集中读取应用配置；配置 ID 用于定位配置和凭据，core 仓库 ID 由目录维护。

import { defaultSyncOptions, normalizeSyncOptions, defaultTodoSettings, SyncOptions as NativeSyncOptions, CoreSettings, Workspace } from 'liborg_tasks_harmony.so'
import { Context } from '@kit.AbilityKit'
import { PreferencesStore } from './PreferencesStore'
import { AppConfig, DEFAULT_CONFIG, RepoConfig, SyncOptions } from '../models/OrgTask'
import { CredentialService } from './CredentialService'

export const APP_CONFIG_PREFERENCES = 'org_tasks_config'
const REPOS_KEY = 'repos'

export class AppConfigService {
  private static changeListeners: Set<() => void> = new Set()

  static watchChanges(listener: () => void): void { AppConfigService.changeListeners.add(listener) }
  static stopWatchingChanges(listener: () => void): void { AppConfigService.changeListeners.delete(listener) }

  static async load(context: Context, includeCredentials: boolean = true): Promise<AppConfig> {
    const store = await PreferencesStore.open(context, APP_CONFIG_PREFERENCES)
    const repos = await AppConfigService.loadRepositories(store, includeCredentials)
    const inboxFile = await store.get('inboxFile', DEFAULT_CONFIG.inboxFile) as string
    const inboxRepoId = await store.get('inboxRepoId', DEFAULT_CONFIG.inboxRepoId) as string
    const somedayFile = await store.get('somedayFile', DEFAULT_CONFIG.somedayFile) as string
    const somedayRepoId = await store.get('somedayRepoId', DEFAULT_CONFIG.somedayRepoId) as string
    const memoFile = await store.get('memoFile', DEFAULT_CONFIG.memoFile) as string
    const memoRepoId = await store.get('memoRepoId', DEFAULT_CONFIG.memoRepoId) as string
    const calendarName = await store.get('calendarName', DEFAULT_CONFIG.calendarName) as string
    const syncInterval = await store.get('syncInterval', DEFAULT_CONFIG.syncInterval) as number
    const todoDefaults = await store.get('todoDefaults', await defaultTodoSettings()) as string
    const savedCoreSettings = await store.get('coreSettings', '') as string
    let coreSettings: CoreSettings = savedCoreSettings ? JSON.parse(savedCoreSettings) as CoreSettings : await new Workspace().getSettings()
    // 旧分类拼写交给 Core 的兼容反序列化处理，设置界面与后续保存只接收规范名称。
    if (savedCoreSettings.includes('"Cancle"')) {
      const migration = new Workspace()
      await migration.setSettings(coreSettings)
      coreSettings = await migration.getSettings()
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
      syncInterval,
      todoDefaults,
      coreSettings,
      fileDisplayMode: fileDisplayMode === 'source' ? 'source' : 'rendered'
    }
  }

  static async save(context: Context, config: AppConfig): Promise<void> {
    for (const file of [config.inboxFile.trim(), config.somedayFile.trim(), config.memoFile.trim()]) {
      if (file && (!file.endsWith('.org') || file.startsWith('/') || file.includes('\\') ||
        file.split('/').some((part: string) => part === '..' || part === '.' || part.length === 0) ||
        file.split('/')[0] === '.sync' || /[\x00-\x1f\x7f]/.test(file))) {
        throw new Error('收件箱、某天和备忘文件必须是存储库中的安全相对 .org 路径，未配置时可留空')
      }
    }
    const validation: Workspace = new Workspace()
    await validation.setTodoDefaults(config.todoDefaults)
    await validation.setSettings(config.coreSettings)
    const store = await PreferencesStore.open(context, APP_CONFIG_PREFERENCES)
    const persisted: RepoConfig[] = []
    for (const repository of config.repos) {
      await normalizeSyncOptions({ excludedDirectories: repository.excludedDirectories } as SyncOptions)
    }
    for (const repository of config.repos) {
      await CredentialService.setWebDavPassword(repository.id, repository.webdavPassword)
      persisted.push({
        id: repository.id,
        name: (repository.name || '').trim(),
        rootDirectory: repository.rootDirectory.trim(),
        webdavEnabled: repository.webdavEnabled,
        webdavUrl: repository.webdavUrl.trim(),
        webdavUsername: repository.webdavUsername.trim(),
        webdavPassword: '',
        excludedDirectories: repository.excludedDirectories || []
      })
    }
    await store.put(REPOS_KEY, JSON.stringify(persisted))
    await store.put('inboxFile', config.inboxFile.trim())
    await store.put('inboxRepoId', config.inboxRepoId)
    await store.put('somedayFile', config.somedayFile.trim())
    await store.put('somedayRepoId', config.somedayRepoId)
    await store.put('memoFile', config.memoFile.trim())
    await store.put('memoRepoId', config.memoRepoId)
    await store.put('calendarName', config.calendarName.trim())
    await store.put('syncInterval', config.syncInterval)
    await store.put('todoDefaults', config.todoDefaults)
    await store.put('coreSettings', JSON.stringify(config.coreSettings))
    await store.put('fileDisplayMode', config.fileDisplayMode)
    await store.flush()
    AppConfigService.changeListeners.forEach((listener: () => void): void => { listener() })
  }

  static async removeRepository(context: Context, configId: string): Promise<void> {
    const current = await AppConfigService.load(context)
    await AppConfigService.save(context, {
      repos: current.repos.filter((repo: RepoConfig) => repo.id !== configId),
      inboxFile: current.inboxFile, inboxRepoId: current.inboxRepoId, somedayFile: current.somedayFile,
      somedayRepoId: current.somedayRepoId, memoFile: current.memoFile, memoRepoId: current.memoRepoId,
      calendarName: current.calendarName, syncInterval: current.syncInterval, todoDefaults: current.todoDefaults, coreSettings: current.coreSettings,
      fileDisplayMode: current.fileDisplayMode
    })
    await CredentialService.clearWebDavPassword(configId)
  }

  static newRepository(rootDirectory: string = ''): RepoConfig {
    return {
      id: createRepoId(),
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
      const defaults: NativeSyncOptions = await defaultSyncOptions()
      for (const repository of persisted) {
        repositories.push({
          id: repository.id,
          name: repository.name || '',
          rootDirectory: repository.rootDirectory,
          webdavEnabled: repository.webdavEnabled,
          webdavUrl: repository.webdavUrl,
          webdavUsername: repository.webdavUsername,
          webdavPassword: includeCredentials ? await CredentialService.getWebDavPassword(repository.id) : '',
          excludedDirectories: repository.excludedDirectories ?? defaults.excludedDirectories.slice()
        })
      }
      return repositories
    }

    return []
  }
}

function createRepoId(): string {
  const template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
  let value = ''
  let state = (Date.now() ^ Math.floor(Math.random() * 0x7fffffff)) >>> 0
  for (let index = 0; index < template.length; index++) {
    const character = template.charAt(index)
    if (character === 'x' || character === 'y') {
      state = (state * 1664525 + 1013904223) >>> 0
      const nibble = state & 0x0f
      value += (character === 'x' ? nibble : (nibble & 0x03) | 0x08).toString(16)
    } else {
      value += character
    }
  }
  return value
}
