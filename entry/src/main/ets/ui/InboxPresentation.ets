import { CoreRefileTarget, CoreTask } from '../services/NativeCoreService'

export interface RefileSection { category: string; targets: CoreRefileTarget[] }

// 文件 CATEGORY 只用于分组；每个 Core 目标及其快照身份均予以保留。
export function refileSections(targets: CoreRefileTarget[]): RefileSection[] {
  const groups = new Map<string, RefileSection>()
  for (const target of targets) {
    const category = target.category || ''
    let section = groups.get(category)
    if (!section) { section = { category, targets: [] }; groups.set(category, section) }
    section.targets.push(target)
  }
  const sections: RefileSection[] = []
  groups.forEach((section: RefileSection) => sections.push(section))
  return sections.sort((left: RefileSection, right: RefileSection): number => {
    if (!left.category) return right.category ? 1 : 0
    if (!right.category) return -1
    return left.category < right.category ? -1 : left.category > right.category ? 1 : 0
  })
}

export interface RecentDay { key: string; date: string; weekday: string; tasks: CoreTask[] }

// 查询已由 Core 排序与筛选；这里仅将有效的创建时间按本地日期组织，不丢弃记录。
export function recentDays(tasks: CoreTask[], reference: Date = new Date()): RecentDay[] {
  const days = new Map<string, RecentDay>()
  const weekdays: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六']
  for (const task of tasks) {
    const date = new Date(task.createdAt!)
    const key = `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`
    let day = days.get(key)
    if (!day) {
      day = { key, date: `${date.getFullYear() !== reference.getFullYear() ? `${date.getFullYear()}年` : ''}${date.getMonth() + 1}月${date.getDate()}日`,
        weekday: weekdays[date.getDay()], tasks: [] }
      days.set(key, day)
    }
    day.tasks.push(task)
  }
  const result: RecentDay[] = []
  days.forEach((day: RecentDay) => result.push(day))
  return result
}

export function unplannedSpacer(viewHeight: number, rowsHeight: number): number {
  return Math.max(48, viewHeight * 0.75 - rowsHeight)
}
