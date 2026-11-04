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

export interface TaskCategory {
  key: string
  title: string
  category: string | null
  count: number
}

// 只组合 core 返回的快照；仓库身份参与文件和任务关联。
export class NotebookService {
  static categoryKey(category: string | null): string {
    return category ? `category:${category}` : 'uncategorized'
  }

  static categories(notebooks: Notebook[]): TaskCategory[] {
    const categories: TaskCategory[] = []
    for (const notebook of notebooks) {
      const category = notebook.category || null
      const key = NotebookService.categoryKey(category)
      const existing = categories.find((item: TaskCategory) => item.key === key)
      if (existing) {
        existing.count += notebook.tasks.length
      } else {
        categories.push({ key, title: category || '未分类', category, count: notebook.tasks.length })
      }
    }
    return categories.sort((left: TaskCategory, right: TaskCategory) => {
      if (left.category === null) return right.category === null ? 0 : 1
      if (right.category === null) return -1
      return left.title.localeCompare(right.title)
    })
  }

  static tasksInCategory(notebooks: Notebook[], category: string | null): CoreTask[] {
    const key = NotebookService.categoryKey(category)
    const tasks: CoreTask[] = []
    for (const notebook of notebooks) {
      if (NotebookService.categoryKey(notebook.category) === key) tasks.push(...notebook.tasks)
    }
    return tasks
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
