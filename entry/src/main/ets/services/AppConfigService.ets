// 集中读取应用配置，并为新配置初始化稳定仓库标识。

import { Context } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { CredentialService } from './CredentialService'

export const APP_CONFIG_PREFERENCES = 'org_tasks_config'
const REPO_ID_KEY = 'repoId'

export class AppConfigService {
  static async load(context: Context): Promise<AppConfig> {
    const store = await preferences.getPreferences(context, APP_CONFIG_PREFERENCES)
    let repoId = await store.get(REPO_ID_KEY, '') as string
    if (!repoId.trim()) {
      repoId = createRepoId()
      await store.put(REPO_ID_KEY, repoId)
      await store.flush()
    }

    const orgDir = await store.get('orgDir', DEFAULT_CONFIG.orgDir) as string
    const inboxFile = await store.get('inboxFile', DEFAULT_CONFIG.inboxFile) as string
    const calendarName = await store.get('calendarName', DEFAULT_CONFIG.calendarName) as string
    const syncInterval = await store.get('syncInterval', DEFAULT_CONFIG.syncInterval) as number
    const webdavEnabled = await store.get('webdavEnabled', DEFAULT_CONFIG.webdavEnabled) as boolean
    const webdavUrl = await store.get('webdavUrl', DEFAULT_CONFIG.webdavUrl) as string
    const webdavUsername = await store.get('webdavUsername', DEFAULT_CONFIG.webdavUsername) as string
    const webdavPassword = await CredentialService.getWebDavPassword(repoId)
    return {
      repoId,
      orgDir,
      inboxFile,
      calendarName,
      syncInterval,
      webdavEnabled,
      webdavUrl,
      webdavUsername,
      webdavPassword
    }
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
