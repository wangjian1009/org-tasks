import { util } from '@kit.ArkTS'
import { RepoConfig } from '../models/OrgTask'
import { CoreTask, CoreTodoMetadata, NativeCoreService } from './NativeCoreService'

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
