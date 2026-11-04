import { util } from '@kit.ArkTS'
import { RepoConfig } from '../models/OrgTask'
import { CoreBridgeError, CoreOrgFileMetadata, CoreTask, CoreTodoMetadata, NativeCoreService, coreErrorMessage } from './NativeCoreService'
import { repositoryLabel } from '../ui/Theme'

export interface NotebookGroup {
  repoId: string
  configId: string
  name: string
  rootDirectory: string
  files: CoreOrgFileMetadata[]
  message: string
}

export interface Notebook {
  id: string
  repoId: string
  rootDirectory: string
  path: string
  source: string
  byteLength: number
  todo: CoreTodoMetadata
  category: string | null
  tasks: CoreTask[]
}

// 只组合 core 返回的文件对象与任务投影，分类和记录选择通过 Workspace.query 处理。
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

  static async load(repositories: RepoConfig[], todoDefaults?: string): Promise<Notebook[]> {
    const response = await NativeCoreService.loadWorkspace(repositories, todoDefaults)
    const notebooks: Notebook[] = []
    for (const repo of await response.workspace.repos()) {
      for (const file of await repo.files()) {
        const bytes = file.sourceBytes()
        notebooks.push({
          id: `${repo.id}:${file.path}`,
          repoId: file.repoId,
          rootDirectory: repo.rootDirectory,
          path: file.path,
          source: util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(bytes),
          byteLength: bytes.byteLength,
          todo: file.todo,
          category: file.category(),
          tasks: response.tasks.filter((task: CoreTask) => task.repoId === file.repoId && task.filePath === file.path)
        })
      }
    }
    return notebooks
  }
}
