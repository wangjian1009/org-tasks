import { CoreRefileTarget, CoreTask } from '../services/NativeCoreService'
import { UiSize } from './Theme'

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

export interface RecentTaskGroup { key: string; project: string | null; tasks: CoreTask[] }
export interface RecentDay { key: string; date: string; weekday: string; tasks: CoreTask[]; groups: RecentTaskGroup[] }

// 查询已由 Core 排序与筛选；这里只按本地创建日期及项目组织展示，不丢弃记录。
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
    const projects = new Map<string, RecentTaskGroup>()
    day.tasks.forEach((task: CoreTask, index: number) => {
      const project = task.project()
      if (project !== null) {
        const key = JSON.stringify(['project', task.category || null, project])
        let group = projects.get(key)
        if (!group) {
          group = { key, project, tasks: [] }
          projects.set(key, group)
          day.groups.push(group)
        }
        group.tasks.push(task)
      } else {
        day.groups.push({ key: JSON.stringify(['task', index, task.id]), project: null, tasks: [task] })
      }
    })
    result.push(day)
  })
  return result
}

export function unplannedSpacer(viewHeight: number, rowsHeight: number): number {
  return Math.max(48, viewHeight * 0.75 - rowsHeight)
}

// 以最多目标的分类计算高度，最多显示四行；小窗口为锚点和系统栏留出空间。
export function targetPopupHeight(sections: RefileSection[], availableHeight: number,
  loading: boolean = false, message: string = '', busy: boolean = false): number {
  let count = 0
  for (const section of sections) count = Math.max(count, section.targets.length)
  const body = loading ? 64 : count > 0 ? 40 + 8 + Math.min(4, count) * UiSize.taskRow : 80
  const height = 48 + 1 + 8 + body + (message ? 124 : 0) + (busy ? 40 : 0)
  return Math.min(height, Math.max(160, availableHeight - 104))
}
