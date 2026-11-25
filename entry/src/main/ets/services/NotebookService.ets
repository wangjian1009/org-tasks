import { localizedText } from '../ui/LocalizedText'
import { AppConfig } from '../models/OrgTask'
import { CoreBridgeError, CoreOrgFileMetadata, NativeCoreService, fileResult, coreErrorMessage } from './NativeCoreService'
import { PageQueryService } from './PageQueryService'
import { repositoryLabel } from '../ui/Theme'

export interface NotebookGroup {
  repoId: string
  configId: string
  name: string
  rootDirectory: string
  files: CoreOrgFileMetadata[]
  message: string
}

// 文件清单与完整内容均由 Core 提供，ArkTS 只组装页面请求。
export class NotebookService {
  // 列表只取 Core 文件元信息，不解码原文或生成任务列表。
  static async list(config: AppConfig): Promise<NotebookGroup[]> {
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    let files: CoreOrgFileMetadata[] = []
    let message: string = ''
    try { files = fileResult((await PageQueryService.query(config, [{ type: 'file', query: { includeIgnored: true } }]))[0]) }
    catch (e) { message = localizedText($r('app.string.text_failed_to_read_file'), String(coreErrorMessage(e as CoreBridgeError))) }
    const groups: NotebookGroup[] = []
    for (const repo of await workspace.repos()) {
      const repository = config.repos.find(item => item.rootDirectory === repo.rootDirectory)
      groups.push({ repoId: repo.id, configId: repository?.id || '', name: repositoryLabel(repository),
        rootDirectory: repo.rootDirectory, files: files.filter(file => file.repoId === repo.id), message })
    }
    return groups
  }
}
