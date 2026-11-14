import { CoreQuery, CoreTaskQuery } from './NativeCoreService'
import { TaskRegionData } from '../ui/TaskRegionPresentation'

// 只组装界面所需的查询请求；任务筛选、完成类型与父子关系均由 core 求值。
export function inboxRecordQuery(inboxFile: string): CoreTaskQuery {
  const path = inboxFile.replace(/\\/g, '\\\\').replace(/"/g, '\\"')
  return { expression: `b."${path}"`, includeDone: true, includeComposeTasks: true }
}

export function memoRecordQuery(memoFile: string, tag: string = ''): CoreTaskQuery {
  const escapedTag = tag.replace(/\\/g, '\\\\').replace(/"/g, '\\"')
  const tagExpression = tag.length > 0 ? ` t."${escapedTag}"` : ''
  return { expression: `${inboxRecordQuery(memoFile).expression}${tagExpression} .o.modified`, includeDone: true, includeComposeTasks: true }
}

// TODO 来自所选仓库，note 仅来自配置的备忘文件；地址与完成状态由 Core 判断。
export function shareLocationTaskQuery(memoFile: string = ''): CoreTaskQuery {
  const scope = memoFile ? `(it.todo or (${inboxRecordQuery(memoFile).expression} it.none))` : 'it.todo'
  return { expression: `has.address ${scope}`, includeDone: false, includeComposeTasks: true }
}

export type TaskOverview = 'today' | 'planned' | 'anytime' | 'someday' | 'memo' | 'logbook'

export function overviewTitle(view: TaskOverview): string {
  switch (view) {
    case 'today': return '今天'
    case 'planned': return '计划'
    case 'anytime': return '随时'
    case 'someday': return '某天'
    case 'memo': return '备忘'
    case 'logbook': return '日志簿'
  }
}

export function overviewTaskQuery(view: TaskOverview, somedayFile: string = '', memoFile: string = ''): CoreTaskQuery {
  let expression = ''
  switch (view) {
    case 'today': expression = '(s.le.today or d.le.today)'; break
    case 'planned': expression = '.is.habit ((s.ge.tomorrow d.ge.tomorrow) or (s.ge.tomorrow d.none) or (s.none d.ge.tomorrow))'; break
    case 'anytime': expression = 'it.todo s.none d.none'; break
    case 'someday': expression = `${inboxRecordQuery(somedayFile).expression} it.todo`; break
    case 'memo': return memoRecordQuery(memoFile)
    case 'logbook': expression = 'it.done'; break
  }
  return { expression, includeDone: view === 'logbook', includeComposeTasks: true }
}

export function todayPriorityQuery(): CoreTaskQuery {
  const query = overviewTaskQuery('today')
  query.expression += ' o.priority'
  return query
}

export function overdueTaskQuery(): CoreTaskQuery {
  return { expression: '(s.le.yesterday or d.le.yesterday)', includeDone: false, includeComposeTasks: true }
}

// 分类与项目共用一个选择；项目由仓库和文件定位，避免跨仓库同名文件混入。
export function plannedRegionQuery(region: TaskRegionData | null): CoreQuery {
  const query = overviewTaskQuery('planned')
  if (region?.kind === 'category') {
    query.categories = [region.category]
  } else if (region?.kind === 'project') {
    query.expression = `(${query.expression}) ${inboxRecordQuery(region.filePath).expression}`
    return { type: 'task', query, repoIds: [region.repoId] }
  }
  return { type: 'task', query }
}
