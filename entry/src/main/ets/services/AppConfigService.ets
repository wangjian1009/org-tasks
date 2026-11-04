// 集中读取应用配置；配置 ID 用于定位配置和凭据，core 仓库 ID 由目录维护。

import { defaultSyncOptions, normalizeSyncOptions, defaultTodoSettings, Workspace } from 'liborg_tasks_harmony.so'
import { Context } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { AppConfig, DEFAULT_CONFIG, RepoConfig, SyncOptions } from '../models/OrgTask'
import { CredentialService } from './CredentialService'

export const APP_CONFIG_PREFERENCES = 'org_tasks_config'
const REPOS_KEY = 'repos'

export class AppConfigService {
  static async load(context: Context): Promise<AppConfig> {
    const store = await preferences.getPreferences(context, APP_CONFIG_PREFERENCES)
    const repos = await AppConfigService.loadRepositories(store)
    const inboxFile = await store.get('inboxFile', DEFAULT_CONFIG.inboxFile) as string
    const somedayFile = await store.get('somedayFile', DEFAULT_CONFIG.somedayFile) as string
    const calendarName = await store.get('calendarName', DEFAULT_CONFIG.calendarName) as string
    const syncInterval = await store.get('syncInterval', DEFAULT_CONFIG.syncInterval) as number
    const todoDefaults = await store.get('todoDefaults', await defaultTodoSettings()) as string
    return {
      repos,
      inboxFile,
      somedayFile,
      calendarName,
      syncInterval,
      todoDefaults
    }
  }

  static async save(context: Context, config: AppConfig): Promise<void> {
    for (const file of [config.inboxFile.trim(), config.somedayFile.trim()]) {
      if (file && (!file.endsWith('.org') || file.startsWith('/') || file.includes('\\') ||
        file.split('/').some((part: string) => part === '..' || part === '.' || part.length === 0) ||
        file.split('/')[0] === '.sync' || /[\x00-\x1f\x7f]/.test(file))) {
        throw new Error('收件箱和某天文件必须是存储库中的安全相对 .org 路径，未配置时可留空')
      }
    }
    const validation = new Workspace()
    await validation.setTodoDefaults(config.todoDefaults)
    const store = await preferences.getPreferences(context, APP_CONFIG_PREFERENCES)
    const persisted: RepoConfig[] = []
    for (const repository of config.repos) {
      await normalizeSyncOptions({ excludedDirectories: repository.excludedDirectories } as SyncOptions)
    }
    for (const repository of config.repos) {
      await CredentialService.setWebDavPassword(repository.id, repository.webdavPassword)
      persisted.push({
        id: repository.id,
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
    await store.put('somedayFile', config.somedayFile.trim())
    await store.put('calendarName', config.calendarName.trim())
    await store.put('syncInterval', config.syncInterval)
    await store.put('todoDefaults', config.todoDefaults)
    await store.flush()
  }

  static newRepository(rootDirectory: string = ''): RepoConfig {
    return {
      id: createRepoId(),
      rootDirectory,
      webdavEnabled: false,
      webdavUrl: '',
      webdavUsername: '',
      webdavPassword: '',
      excludedDirectories: []
    }
  }

  private static async loadRepositories(store: preferences.Preferences): Promise<RepoConfig[]> {
    const encoded = await store.get(REPOS_KEY, '') as string
    if (encoded.length > 0) {
      const persisted = JSON.parse(encoded) as RepoConfig[]
      const repositories: RepoConfig[] = []
      const defaults = await defaultSyncOptions()
      for (const repository of persisted) {
        repositories.push({
          id: repository.id,
          rootDirectory: repository.rootDirectory,
          webdavEnabled: repository.webdavEnabled,
          webdavUrl: repository.webdavUrl,
          webdavUsername: repository.webdavUsername,
          webdavPassword: await CredentialService.getWebDavPassword(repository.id),
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
