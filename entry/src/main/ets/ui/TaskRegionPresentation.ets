import { CoreTask } from '../services/NativeCoreService'

export interface TaskRegion {
  key: string
  kind: 'category' | 'project'
  title: string
  repoId: string
  filePath: string
}

export interface TaskRegionGroup<T> extends TaskRegion {
  items: T[]
}

// 项目优先归组，其余任务按分类归组；只组织已有快照，不筛选或复制任务。
export function taskRegionGroups<T>(items: T[], taskOf: (item: T) => CoreTask): TaskRegionGroup<T>[] {
  const regions = new Map<string, TaskRegionGroup<T>>()
  for (const item of items) {
    const task = taskOf(item)
    const project = task.project()
    const category = task.category || null
    const kind: 'category' | 'project' = project === null ? 'category' : 'project'
    const key = JSON.stringify(project === null ? ['category', category] : ['project', task.repoId, task.filePath])
    let region = regions.get(key)
    if (!region) {
      region = { key, kind, title: project === null ? category || '未分类' : project || '未命名项目',
        repoId: task.repoId, filePath: task.filePath, items: [] }
      regions.set(key, region)
    }
    region.items.push(item)
  }
  const result: TaskRegionGroup<T>[] = []
  regions.forEach((region: TaskRegionGroup<T>) => { result.push(region) })
  return result
}
