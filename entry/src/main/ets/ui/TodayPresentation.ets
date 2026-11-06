import { CoreRepo, CoreTask, CoreWorkspace } from '../services/NativeCoreService'

export interface TodayTaskItem {
  task: CoreTask
  overdueDays: number
}

export interface TodaySection {
  key: string
  category: string | null
  items: TodayTaskItem[]
}

// 只计算展示数字，不据此选择任务；使用自然日序号避免夏令时影响。
export function overdueDays(task: CoreTask, today: Date = new Date()): number {
  const scheduled: string = task.scheduled.slice(0, 10)
  const deadline: string = task.deadline.slice(0, 10)
  const date: string = scheduled && deadline ? (scheduled < deadline ? scheduled : deadline) : scheduled || deadline
  if (!date) return 0
  const time = new Date(`${date}T00:00:00Z`).getTime()
  if (isNaN(time)) return 0
  const current = Date.UTC(today.getFullYear(), today.getMonth(), today.getDate())
  return Math.max(0, Math.floor((current - time) / 86400000))
}

// 保留 Core 查询返回的每一条任务，仅通过 OrgFile.category() 组织展示区块。
export async function todaySections(tasks: CoreTask[], workspace: CoreWorkspace,
  today: Date = new Date()): Promise<TodaySection[]> {
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
    section.items.push({ task, overdueDays: overdueDays(task, today) })
  }
  const result: TodaySection[] = []
  sections.forEach((section: TodaySection) => { result.push(section) })
  return result.sort((left: TodaySection, right: TodaySection) => {
    if (left.category === null) return right.category === null ? 0 : 1
    if (right.category === null) return -1
    return left.category < right.category ? -1 : left.category > right.category ? 1 : 0
  })
}
