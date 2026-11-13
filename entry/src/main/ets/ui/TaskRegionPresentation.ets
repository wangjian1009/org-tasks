import { CoreTask } from '../services/NativeCoreService'

export interface TaskRegion {
  key: string
  kind: 'category' | 'project'
  title: string
  category: string | null
  repoId: string
  filePath: string
}

export interface TaskRegionGroup<T> extends TaskRegion {
  items: T[]
}

export function taskRegion(task: CoreTask): TaskRegion {
  const project = task.project()
  const category = task.category || null
  return {
    key: JSON.stringify(project === null ? ['category', category] : ['project', task.repoId, task.filePath]),
    kind: project === null ? 'category' : 'project',
    title: project === null ? category || '未分类' : project || '未命名项目',
    category, repoId: task.repoId, filePath: task.filePath
  }
}

export function taskRegionTitle(region: TaskRegion, category: boolean, project: boolean): string {
  const categoryTitle = category ? region.category || '未分类' : ''
  const projectTitle = project && region.kind === 'project' ? region.title : ''
  return categoryTitle && projectTitle ? `${categoryTitle} · ${projectTitle}` : categoryTitle || projectTitle
}

// 项目优先归组，其余任务按分类归组；只组织已有快照，不筛选或复制任务。
export function taskRegionGroups<T>(items: T[], taskOf: (item: T) => CoreTask): TaskRegionGroup<T>[] {
  const regions = new Map<string, TaskRegionGroup<T>>()
  for (const item of items) {
    const task = taskOf(item)
    const source = taskRegion(task)
    let region = regions.get(source.key)
    if (!region) {
      region = { key: source.key, kind: source.kind, title: source.title, category: source.category,
        repoId: source.repoId, filePath: source.filePath, items: [] }
      regions.set(source.key, region)
    }
    region.items.push(item)
  }
  const result: TaskRegionGroup<T>[] = []
  regions.forEach((region: TaskRegionGroup<T>) => { result.push(region) })
  return result
}
