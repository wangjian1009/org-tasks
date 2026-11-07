import { CoreTask } from '../services/NativeCoreService'

export interface TaskTagSelection {
  tags: string[]
  includeUntagged: boolean
}

export function taskTagOptions(tasks: CoreTask[]): string[] {
  const tags = new Set<string>()
  tasks.forEach((task: CoreTask) => {
    task.tags.forEach((tag: string) => { tags.add(tag) })
  })
  return Array.from(tags).sort((left: string, right: string) => left.localeCompare(right))
}

export function allTaskTagsSelected(selection: TaskTagSelection): boolean {
  return selection.tags.length === 0 && !selection.includeUntagged
}

export function toggleTaskTag(selection: TaskTagSelection, tag: string): TaskTagSelection {
  const tags = selection.tags.includes(tag)
    ? selection.tags.filter((selected: string) => selected !== tag) : selection.tags.concat(tag)
  return { tags, includeUntagged: selection.includeUntagged }
}

export function reconcileTaskTags(selection: TaskTagSelection, options: string[]): TaskTagSelection {
  return { tags: selection.tags.filter((tag: string) => options.includes(tag)),
    includeUntagged: selection.includeUntagged }
}

// 今天、随时、某天的标签筛选是展示层例外，只处理当前页面已加载的任务快照。
export function filterTasksByTags(tasks: CoreTask[], selection: TaskTagSelection): CoreTask[] {
  if (allTaskTagsSelected(selection)) return tasks
  return tasks.filter((task: CoreTask) => {
    return (selection.includeUntagged && task.tags.length === 0)
      || selection.tags.some((tag: string) => task.tags.includes(tag))
  })
}
