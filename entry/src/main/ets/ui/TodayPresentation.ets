import { CoreTask } from '../services/NativeCoreService'
import { TaskTimeDisplay } from './TaskListPresentation'
import { localDate } from './Theme'

export interface TodayTaskItem {
  task: CoreTask
}

export interface TodayTimedTaskItem {
  task: CoreTask
  time: string
  timeDisplay: TaskTimeDisplay
}

export interface TodayLayout {
  timedItems: TodayTimedTaskItem[]
  sections: TodaySection[]
}

// 将同一快照无损分为今天时刻与原分类区域，不改变页面查询范围或任务总数。
export function todayLayout(tasks: CoreTask[], priorityOrder: string[], today: Date): TodayLayout {
  const date = localDate(today)
  const timedItems: TodayTimedTaskItem[] = []
  const ordinary: CoreTask[] = []
  const ranks = new Map<string, number>()
  priorityOrder.forEach((id: string, index: number) => { ranks.set(id, index) })
  tasks.forEach((task: CoreTask) => {
    const scheduled = task.editContent?.scheduledPlanning
    const deadline = task.editContent?.deadlinePlanning
    if (scheduled?.date === date && scheduled.time !== null) {
      timedItems.push({ task, time: scheduled.time.start, timeDisplay: TaskTimeDisplay.Schedule })
    } else if (deadline?.date === date && deadline.time !== null) {
      timedItems.push({ task, time: deadline.time.start, timeDisplay: TaskTimeDisplay.Deadline })
    } else {
      ordinary.push(task)
    }
  })
  timedItems.sort((left: TodayTimedTaskItem, right: TodayTimedTaskItem): number => {
    if (left.time !== right.time) return left.time < right.time ? -1 : 1
    return (ranks.get(left.task.id) ?? priorityOrder.length) - (ranks.get(right.task.id) ?? priorityOrder.length)
  })
  return { timedItems, sections: todaySections(ordinary, true, priorityOrder) }
}

export interface TodayTaskGroup {
  key: string
  project: string | null
  items: TodayTaskItem[]
}

export interface TodaySection {
  key: string
  category: string | null
  items: TodayTaskItem[]
  groups: TodayTaskGroup[]
}

// 保留 Core 查询返回的每一条任务，仅按任务快照中的文件分类组织展示区块。
export function todaySections(tasks: CoreTask[], groupProjects: boolean = false, priorityOrder: string[] = []): TodaySection[] {
  if (tasks.length === 0) return []
  const ranks = new Map<string, number>()
  priorityOrder.forEach((id: string, index: number) => { ranks.set(id, index) })
  const sections = new Map<string, TodaySection>()
  for (const task of tasks) {
    const category = task.category || null
    const key = category === null ? 'uncategorized' : `category:${category}`
    let section = sections.get(key)
    if (!section) {
      section = { key, category, items: [], groups: [] }
      sections.set(key, section)
    }
    section.items.push({ task })
  }
  const result: TodaySection[] = []
  sections.forEach((section: TodaySection) => {
    const projects = new Map<string, TodayTaskGroup>()
    section.items.forEach((item: TodayTaskItem, index: number) => {
      const project = groupProjects ? item.task.project() : null
      if (project !== null) {
        const projectKey = JSON.stringify([item.task.repoId, item.task.filePath, project])
        let group = projects.get(projectKey)
        if (!group) {
          group = { key: JSON.stringify(['project', projectKey]), project, items: [] }
          projects.set(projectKey, group)
          section.groups.push(group)
        }
        group.items.push(item)
      } else {
        section.groups.push({ key: JSON.stringify(['task', index, item.task.id]), project: null, items: [item] })
      }
    })
    if (priorityOrder.length > 0) {
      // 仅使用同批 Core 查询的顺序，不在展示层计算优先级或默认值。
      const compare = (left: TodayTaskItem, right: TodayTaskItem): number =>
        (ranks.get(left.task.id) ?? priorityOrder.length) - (ranks.get(right.task.id) ?? priorityOrder.length)
      const ordinary: TodayTaskGroup[] = []
      section.groups.forEach((group: TodayTaskGroup) => {
        if (group.project === null) ordinary.push(group)
        else group.items.sort(compare)
      })
      ordinary.sort((left: TodayTaskGroup, right: TodayTaskGroup) => compare(left.items[0], right.items[0]))
      let index = 0
      section.groups = section.groups.map((group: TodayTaskGroup): TodayTaskGroup =>
        group.project === null ? ordinary[index++] : group)
    }
    result.push(section)
  })
  return result.sort((left: TodaySection, right: TodaySection) => {
    if (left.category === null) return right.category === null ? 0 : 1
    if (right.category === null) return -1
    return left.category < right.category ? -1 : left.category > right.category ? 1 : 0
  })
}
