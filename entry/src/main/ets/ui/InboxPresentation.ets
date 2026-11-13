import { CoreTask } from '../services/NativeCoreService'
import { TaskRegionGroup, taskRegionGroups } from './TaskRegionPresentation'

export type RecentTaskGroup = TaskRegionGroup<CoreTask>
export interface RecentDay { key: string; date: string; weekday: string; tasks: CoreTask[]; groups: RecentTaskGroup[] }

// 查询已由 Core 排序与筛选；这里只按本地创建日期及平级分类／项目组织展示，不丢弃记录。
export function recentDays(tasks: CoreTask[], reference: Date = new Date()): RecentDay[] {
  const days = new Map<string, RecentDay>()
  const weekdays: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六']
  for (const task of tasks) {
    const date = new Date(task.createdAt!)
    const key = `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`
    let day = days.get(key)
    if (!day) {
      day = { key, date: `${date.getFullYear() !== reference.getFullYear() ? `${date.getFullYear()}年` : ''}${date.getMonth() + 1}月${date.getDate()}日`,
        weekday: weekdays[date.getDay()], tasks: [], groups: [] }
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
