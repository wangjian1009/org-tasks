import { CoreRepo, CoreTask, CoreWorkspace } from '../services/NativeCoreService'

export interface TodayTaskItem {
  task: CoreTask
}

export interface TodaySection {
  key: string
  category: string | null
  items: TodayTaskItem[]
}

// 保留 Core 查询返回的每一条任务，仅通过 OrgFile.category() 组织展示区块。
export async function todaySections(tasks: CoreTask[], workspace: CoreWorkspace): Promise<TodaySection[]> {
  if (tasks.length === 0) return []
  const repos = await workspace.repos()
  const fileCategories = new Map<string, string | null>()
  const sections = new Map<string, TodaySection>()
  for (const task of tasks) {
    const fileKey = `${task.repoId}:${task.filePath}`
    if (!fileCategories.has(fileKey)) {
      const repo = repos.find((item: CoreRepo) => item.id === task.repoId)
      if (!repo) throw new Error('任务所属存储库不可用')
      const file = await repo.file(task.filePath)
      fileCategories.set(fileKey, file.category() || null)
    }
    const category = fileCategories.get(fileKey) ?? null
    const key = category === null ? 'uncategorized' : `category:${category}`
    let section = sections.get(key)
    if (!section) {
      section = { key, category, items: [] }
      sections.set(key, section)
    }
    section.items.push({ task })
  }
  const result: TodaySection[] = []
  sections.forEach((section: TodaySection) => { result.push(section) })
  return result.sort((left: TodaySection, right: TodaySection) => {
    if (left.category === null) return right.category === null ? 0 : 1
    if (right.category === null) return -1
    return left.category < right.category ? -1 : left.category > right.category ? 1 : 0
  })
}
