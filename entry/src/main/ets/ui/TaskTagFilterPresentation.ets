import { CoreTask } from '../services/NativeCoreService'

export interface TaskTagSelection {
  tags: string[]
  includeUntagged: boolean
}

export function taskTagOptions(tasks: CoreTask[], configuredTags: string[] = []): string[] {
  const tags = new Set<string>(configuredTags)
  tasks.forEach((task: CoreTask) => {
    task.tags.forEach((tag: string) => { tags.add(tag) })
  })
  return Array.from(tags).sort((left: string, right: string) => left.localeCompare(right))
}

export function allTaskTagsSelected(selection: TaskTagSelection): boolean {
  return selection.tags.length === 0 && !selection.includeUntagged
}

export function toggleTaskTag(selection: TaskTagSelection, tag: string, exclusiveGroups: string[][] = []): TaskTagSelection {
  const tags = selection.tags.includes(tag)
    ? selection.tags.filter((selected: string) => selected !== tag)
    : selection.tags.filter((selected: string) => !exclusiveGroups.some((group: string[]) =>
      group.includes(tag) && group.includes(selected))).concat(tag)
  return { tags, includeUntagged: selection.includeUntagged }
}

export function groupedTaskTags(tags: string[], exclusiveGroups: string[][]): string[][] {
  const groups = exclusiveGroups.map((group: string[]) => group.filter((tag: string) => tags.includes(tag)))
    .filter((group: string[]) => group.length > 0)
  const others = tags.filter((tag: string) => !exclusiveGroups.some((group: string[]) => group.includes(tag)))
  if (others.length > 0) groups.push(others)
  return groups
}

export function reconcileTaskTags(selection: TaskTagSelection, options: string[], exclusiveGroups: string[][] = []): TaskTagSelection {
  const valid = selection.tags.filter((tag: string) => options.includes(tag))
  if (exclusiveGroups.length === 0) return { tags: valid, includeUntagged: selection.includeUntagged }
  return valid.reduce((current: TaskTagSelection, tag: string) => toggleTaskTag(current, tag, exclusiveGroups),
    { tags: [], includeUntagged: selection.includeUntagged })
}

// 今天、随时、某天和备忘的标签筛选是展示层例外，只处理当前页面已加载的任务快照。
export function filterTasksByTags(tasks: CoreTask[], selection: TaskTagSelection, exclusiveGroups: string[][] = []): CoreTask[] {
  if (allTaskTagsSelected(selection)) return tasks
  const selectedGroups = exclusiveGroups.map((group: string[]) =>
    group.filter((tag: string) => selection.tags.includes(tag))).filter((group: string[]) => group.length > 0)
  const others = selection.tags.filter((tag: string) => !exclusiveGroups.some((group: string[]) => group.includes(tag)))
  if (others.length > 0) selectedGroups.push(others)
  return tasks.filter((task: CoreTask) => {
    return (selection.includeUntagged && task.tags.length === 0)
      || (selection.tags.length > 0 && selectedGroups.every((group: string[]) => group.some((tag: string) => task.tags.includes(tag))))
  })
}
