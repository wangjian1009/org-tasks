import { RepoConfig } from '../models/OrgTask'
import { CoreTask, NativeCoreService } from './NativeCoreService'

export interface Notebook {
  id: string
  repoId: string
  rootDirectory: string
  path: string
  source: string
  byteLength: number
  tasks: CoreTask[]
}

// 只组合 core 返回的快照；仓库身份参与文件和任务关联。
export class NotebookService {
  static async load(repositories: RepoConfig[]): Promise<Notebook[]> {
    const response = await NativeCoreService.loadWorkspace(repositories)
    const notebooks: Notebook[] = []
    for (const repo of response.workspace.repos) {
      for (const file of repo.files) {
        notebooks.push({
          id: `${repo.id}:${file.path}`,
          repoId: repo.id,
          rootDirectory: repo.rootDirectory,
          path: file.path,
          source: file.source,
          byteLength: file.byte_length,
          tasks: response.tasks.filter((task: CoreTask) => task.repoId === repo.id && task.filePath === file.path)
        })
      }
    }
    return notebooks
  }
}
