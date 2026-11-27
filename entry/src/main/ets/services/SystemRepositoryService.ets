import { bundledLocale, localizedText } from '../ui/LocalizedText'
import { Context } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { RepoConfig } from '../models/OrgTask'

import { SYSTEM_REPOSITORY_ID, TRASH_FILE } from '../models/SystemRepository'
export { SYSTEM_REPOSITORY_ID, TRASH_FILE } from '../models/SystemRepository'

// 系统目录属于应用沙箱，初始化只补齐缺失文件，已有废纸篓绝不覆盖。
export class SystemRepositoryService {
  private static initialization: Promise<RepoConfig> | undefined = undefined

  static isSystem(repository: RepoConfig): boolean { return repository.id === SYSTEM_REPOSITORY_ID }

  static ensure(context: Context): Promise<RepoConfig> {
    if (!SystemRepositoryService.initialization) {
      SystemRepositoryService.initialization = SystemRepositoryService.initialize(context).catch((error: Error): RepoConfig => {
        SystemRepositoryService.initialization = undefined
        throw error
      })
    }
    return SystemRepositoryService.initialization
  }

  private static async initialize(context: Context): Promise<RepoConfig> {
    const directory = `${context.filesDir}/system-repository`
    try {
    if (!await fs.access(directory)) await fs.mkdir(directory, true)
    const path = `${directory}/${TRASH_FILE}`
    if (!await fs.access(path)) {
      const template = await context.resourceManager.getRawFileContent(`templates/${bundledLocale()}/trash.org`)
      const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY)
      try { await fs.write(file.fd, template.buffer); await fs.fsync(file.fd) }
      finally { await fs.close(file) }
    }
    } catch (_) { throw new Error(localizedText($r('app.string.text_system_repository_initialization_failed_try_again'))) }
    return { id: SYSTEM_REPOSITORY_ID, name: localizedText($r('app.string.text_system_repository')), rootDirectory: directory, webdavEnabled: false,
      webdavUrl: '', webdavUsername: '', webdavPassword: '', excludedDirectories: [] }
  }
}
