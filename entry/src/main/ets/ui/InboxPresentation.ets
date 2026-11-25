import { localizedDate } from './LocalizedText'
import { CoreTask } from '../services/NativeCoreService'
import { TaskRegionGroup, taskRegionGroups } from './TaskRegionPresentation'

export type RecentTaskGroup = TaskRegionGroup<CoreTask>
export interface RecentDay { key: string; date: string; weekday: string; tasks: CoreTask[]; groups: RecentTaskGroup[] }

// 查询已由 Core 排序与筛选；这里只按本地创建日期及平级分类／项目组织展示，不丢弃记录。
export function recentDays(tasks: CoreTask[], reference: Date = new Date()): RecentDay[] {
  const days = new Map<string, RecentDay>()
  for (const task of tasks) {
    const date = new Date(task.createdAt!)
    const key = `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`
    let day = days.get(key)
    if (!day) {
      day = { key, date: localizedDate(date, { month: 'long', day: 'numeric',
        year: date.getFullYear() !== reference.getFullYear() ? 'numeric' : undefined }),
        weekday: localizedDate(date, { weekday: 'short' }), tasks: [], groups: [] }
      days.set(key, day)
    }
    day.tasks.push(task)
  }
  const result: RecentDay[] = []
  days.forEach((day: RecentDay) => {
    day.groups = taskRegionGroups(day.tasks, (task: CoreTask): CoreTask => task)
    result.push(day)
  })
  return result
}

export function unplannedSpacer(viewHeight: number, rowsHeight: number): number {
  return Math.max(48, viewHeight * 0.75 - rowsHeight)
}
