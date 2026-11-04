import { RepoConfig } from '../models/OrgTask'
import { CoreBridgeError, CoreOrgFile, CoreOrgFileMetadata, NativeCoreService, coreErrorMessage } from './NativeCoreService'
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
  static async list(repositories: RepoConfig[], todoDefaults?: string): Promise<NotebookGroup[]> {
    const workspace = await NativeCoreService.workspaceFor(repositories, todoDefaults)
    const groups: NotebookGroup[] = []
    for (const repo of await workspace.repos()) {
      const config = repositories.find((item: RepoConfig) => item.rootDirectory === repo.rootDirectory)
      let files: CoreOrgFileMetadata[] = []
      let message: string = ''
      try { files = await repo.fileMetadata() }
      catch (e) { message = `读取文件失败：${coreErrorMessage(e as CoreBridgeError)}` }
      groups.push({ repoId: repo.id, configId: config?.id || '', name: repositoryLabel(config), rootDirectory: repo.rootDirectory, files, message })
    }
    return groups
  }

  // 完整阅读只打开目标仓库和文件，不查询或过滤任务列表。
  static async open(repositories: RepoConfig[], repoId: string, path: string,
    todoDefaults?: string): Promise<CoreOrgFile | undefined> {
    const workspace = await NativeCoreService.workspaceFor(repositories, todoDefaults)
    const repo = (await workspace.repos()).find((item) => item.id === repoId)
    if (!repo) return undefined
    const files = await repo.fileMetadata()
    if (!files.some((file: CoreOrgFileMetadata) => file.path === path)) return undefined
    return await repo.file(path)
  }
}
