import { CoreTask } from '../services/NativeCoreService'

export interface TodayTaskItem {
  task: CoreTask
}

export interface TodaySection {
  key: string
  category: string | null
  items: TodayTaskItem[]
}

// 保留 Core 查询返回的每一条任务，仅按任务快照中的文件分类组织展示区块。
export function todaySections(tasks: CoreTask[]): TodaySection[] {
  if (tasks.length === 0) return []
  const sections = new Map<string, TodaySection>()
  for (const task of tasks) {
    const category = task.category || null
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
