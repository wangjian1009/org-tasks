import { CoreOrgFileMetadata } from '../services/NativeCoreService'
import { TodayLayout, TodaySection, TodayTaskGroup } from './TodayPresentation'

export interface TodayProjectOrder { region: string; keys: string[] }
export interface TodayRegionOrder { version: number; regions: string[]; projects: TodayProjectOrder[] }
export interface TodayOrderProject { key: string; title: string; taskCount: number }
export interface TodayOrderRegion {
  key: string
  title: string
  taskCount: number
  projects: TodayOrderProject[]
}

export function todayOrderProjectKey(repoId: string, filePath: string): string {
  return JSON.stringify([repoId, filePath])
}

function categoryKey(category: string | null): string { return category ? `category:${category}` : 'uncategorized' }

function compareName(left: string, right: string): number { return left < right ? -1 : left > right ? 1 : 0 }

// 已知文件定义有效分类与项目；今天没有任务不代表排序项失效。
export function todayOrderCatalog(files: CoreOrgFileMetadata[], layout: TodayLayout): TodayOrderRegion[] {
  const regions = new Map<string, TodayOrderRegion>()
  const ensure = (key: string, title: string): TodayOrderRegion => {
    let region = regions.get(key)
    if (!region) { region = { key, title, taskCount: 0, projects: [] }; regions.set(key, region) }
    return region
  }
  for (const file of files) {
    if (file.isIgnore) continue
    const region = ensure(categoryKey(file.category), file.category || '未分类')
    const project = file.project()
    if (project !== null) region.projects.push({ key: todayOrderProjectKey(file.repoId, file.path), title: project || '未命名项目', taskCount: 0 })
  }
  for (const section of layout.sections) {
    const region = ensure(section.key, section.category || '未分类')
    region.taskCount = section.items.length
    for (const group of section.groups) {
      if (group.project === null) continue
      const task = group.items[0].task, key = todayOrderProjectKey(task.repoId, task.filePath)
      let project = region.projects.find(item => item.key === key)
      if (!project) { project = { key, title: group.project || '未命名项目', taskCount: 0 }; region.projects.push(project) }
      project.taskCount = group.items.length
    }
  }
  const result = Array.from(regions.values()).sort((left, right) => {
    if (left.key === 'uncategorized') return right.key === 'uncategorized' ? 0 : 1
    if (right.key === 'uncategorized') return -1
    return compareName(left.title, right.title)
  })
  for (const region of result) region.projects.sort((left, right) => compareName(left.title, right.title) || compareName(left.key, right.key))
  result.unshift({ key: 'schedule', title: '日程', taskCount: layout.timedItems.length, projects: [] })
  return result
}

function orderedKeys(available: string[], saved: string[]): string[] {
  const result = saved.filter((key, index) => available.includes(key) && saved.indexOf(key) === index)
  for (const key of available) if (!result.includes(key)) result.push(key)
  return result
}

// 读取和日常展示只比较位置；失效项不从已保存配置中删除。
export function orderedTodayCatalog(catalog: TodayOrderRegion[], order: TodayRegionOrder | null): TodayOrderRegion[] {
  return orderedKeys(catalog.map(region => region.key), order?.regions ?? []).map((key): TodayOrderRegion => {
    const region = catalog.find(item => item.key === key)!
    const projects = orderedKeys(region.projects.map(project => project.key), order?.projects.find(item => item.region === key)?.keys ?? [])
    return { key, title: region.title, taskCount: region.taskCount,
      projects: projects.map(projectKey => region.projects.find(project => project.key === projectKey)!) }
  })
}

// 仅在确认编辑时由完整有效目录生成新配置，统一清理失效项并登记新增项。
export function todayOrderFromDraft(draft: TodayOrderRegion[], current: TodayOrderRegion[]): TodayRegionOrder {
  const draftOrder: TodayRegionOrder = { version: 1, regions: draft.map(region => region.key),
    projects: draft.map((region): TodayProjectOrder => ({ region: region.key, keys: region.projects.map(project => project.key) })) }
  const valid = orderedTodayCatalog(current, draftOrder)
  return { version: 1, regions: valid.map(region => region.key),
    projects: valid.filter(region => region.projects.length > 0).map((region): TodayProjectOrder => ({ region: region.key, keys: region.projects.map(project => project.key) })) }
}

export function orderTodaySections(sections: TodaySection[], order: TodayRegionOrder | null): TodaySection[] {
  const keys = orderedKeys(sections.map(section => section.key), order?.regions ?? [])
  return keys.map((key): TodaySection => {
    const section = sections.find(item => item.key === key)!
    const projects = section.groups.filter(group => group.project !== null).sort((left, right) =>
      compareName(left.project || '', right.project || '') || compareName(left.key, right.key))
    const projectKey = (group: TodayTaskGroup): string => todayOrderProjectKey(group.items[0].task.repoId, group.items[0].task.filePath)
    const projectKeys = orderedKeys(projects.map(projectKey), order?.projects.find(item => item.region === key)?.keys ?? [])
    return { key: section.key, category: section.category, items: section.items,
      groups: projectKeys.map(id => projects.find(group => projectKey(group) === id)!)
        .concat(section.groups.filter(group => group.project === null)) }
  })
}

export function todayVisibleRegionKeys(sections: TodaySection[], hasSchedule: boolean, order: TodayRegionOrder | null): string[] {
  const available = sections.map(section => section.key)
  if (hasSchedule) available.unshift('schedule')
  return orderedKeys(available, order?.regions ?? [])
}
