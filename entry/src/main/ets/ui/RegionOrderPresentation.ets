import { localizedText } from './LocalizedText'
import { CoreOrgFileMetadata } from '../services/NativeCoreService'
import { TodayLayout, TodaySection, TodayTaskGroup } from './TodayPresentation'

export interface ProjectOrder { region: string; keys: string[] }
export interface RegionOrder { version: number; regions: string[]; projects: ProjectOrder[] }
export interface OrderProject { key: string; title: string; taskCount: number }
export interface OrderRegion {
  key: string
  title: string
  taskCount: number
  projects: OrderProject[]
}

export function orderProjectKey(repoId: string, filePath: string): string {
  return JSON.stringify([repoId, filePath])
}

export function orderRegionKey(category: string | null): string { return category ? `category:${category}` : 'uncategorized' }

function compareName(left: string, right: string): number { return left < right ? -1 : left > right ? 1 : 0 }

// 已知文件定义有效分类与项目；今天没有任务不代表排序项失效。
export function regionOrderCatalog(files: CoreOrgFileMetadata[], layout: TodayLayout): OrderRegion[] {
  const regions = new Map<string, OrderRegion>()
  const allowedFiles = new Set<string>()
  const ensure = (key: string, title: string): OrderRegion => {
    let region = regions.get(key)
    if (!region) { region = { key, title, taskCount: 0, projects: [] }; regions.set(key, region) }
    return region
  }
  for (const file of files) {
    if (file.isIgnore) continue
    allowedFiles.add(orderProjectKey(file.repoId, file.path))
    const region = ensure(orderRegionKey(file.category), file.category || localizedText($r('app.string.text_uncategorized')))
    const project = file.project()
    if (project !== null) region.projects.push({ key: orderProjectKey(file.repoId, file.path), title: project || localizedText($r('app.string.text_untitled_project')), taskCount: 0 })
  }
  for (const section of layout.sections) {
    const region = regions.get(section.key)
    if (!region) continue
    region.taskCount = section.items.filter(item => allowedFiles.has(orderProjectKey(item.task.repoId, item.task.filePath))).length
    for (const group of section.groups) {
      if (group.project === null) continue
      const task = group.items[0].task, key = orderProjectKey(task.repoId, task.filePath)
      const project = region.projects.find(item => item.key === key)
      if (project) project.taskCount = group.items.length
    }
  }
  const result = Array.from(regions.values()).sort((left, right) => {
    if (left.key === 'uncategorized') return right.key === 'uncategorized' ? 0 : 1
    if (right.key === 'uncategorized') return -1
    return compareName(left.title, right.title)
  })
  for (const region of result) region.projects.sort((left, right) => compareName(left.title, right.title) || compareName(left.key, right.key))
  return result
}

export function orderedKeys(available: string[], saved: string[]): string[] {
  const result = saved.filter((key, index) => available.includes(key) && saved.indexOf(key) === index)
  for (const key of available) if (!result.includes(key)) result.push(key)
  return result
}

// 读取和日常展示只比较位置；失效项不从已保存配置中删除。
export function orderedRegionCatalog(catalog: OrderRegion[], order: RegionOrder | null): OrderRegion[] {
  return orderedKeys(catalog.filter(region => region.key !== 'schedule').map(region => region.key), order?.regions ?? []).map((key): OrderRegion => {
    const region = catalog.find(item => item.key === key)!
    const projects = orderedKeys(region.projects.map(project => project.key), order?.projects.find(item => item.region === key)?.keys ?? [])
    return { key, title: region.title, taskCount: region.taskCount,
      projects: projects.map(projectKey => region.projects.find(project => project.key === projectKey)!) }
  })
}

// 仅在确认编辑时由完整有效目录生成新配置，统一清理失效项并登记新增项。
export function regionOrderFromDraft(draft: OrderRegion[], current: OrderRegion[]): RegionOrder {
  const draftOrder: RegionOrder = { version: 1, regions: draft.map(region => region.key),
    projects: draft.map((region): ProjectOrder => ({ region: region.key, keys: region.projects.map(project => project.key) })) }
  const valid = orderedRegionCatalog(current, draftOrder)
  return { version: 1, regions: valid.map(region => region.key),
    projects: valid.filter(region => region.projects.length > 0).map((region): ProjectOrder => ({ region: region.key, keys: region.projects.map(project => project.key) })) }
}

export function orderTodaySections(sections: TodaySection[], order: RegionOrder | null): TodaySection[] {
  const keys = orderedKeys(sections.map(section => section.key), order?.regions ?? [])
  return keys.map((key): TodaySection => {
    const section = sections.find(item => item.key === key)!
    const projects = section.groups.filter(group => group.project !== null).sort((left, right) =>
      compareName(left.project || '', right.project || '') || compareName(left.key, right.key))
    const projectKey = (group: TodayTaskGroup): string => orderProjectKey(group.items[0].task.repoId, group.items[0].task.filePath)
    const projectKeys = orderedKeys(projects.map(projectKey), order?.projects.find(item => item.region === key)?.keys ?? [])
    return { key: section.key, category: section.category, items: section.items,
      groups: projectKeys.map(id => projects.find(group => projectKey(group) === id)!)
        .concat(section.groups.filter(group => group.project === null)) }
  })
}

export function todayVisibleRegionKeys(sections: TodaySection[], hasSchedule: boolean, order: RegionOrder | null): string[] {
  const keys = orderedKeys(sections.map(section => section.key), order?.regions ?? [])
  if (hasSchedule) keys.unshift('schedule')
  return keys
}
