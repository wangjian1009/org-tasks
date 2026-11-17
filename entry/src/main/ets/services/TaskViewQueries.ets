import { CoreQuery, CoreTaskQuery, CoreOrgFileRef } from './NativeCoreService'
import { TaskRegionData } from '../ui/TaskRegionPresentation'

// 只组装查询请求；文件范围由 Core 在扫描时应用，不进入表达式。
export function inboxRecordQuery(file: CoreOrgFileRef): CoreTaskQuery {
  return { expression: '', includeFiles: [file] }
}

export function memoRecordQuery(file: CoreOrgFileRef, tag: string = ''): CoreTaskQuery {
  const escapedTag = tag.replace(/\\/g, '\\\\').replace(/"/g, '\\"')
  const tagExpression = tag.length > 0 ? `t."${escapedTag}" ` : ''
  return { expression: `${tagExpression}.o.modified`, includeFiles: [file] }
}

// 两项查询的状态范围互斥；待办来自所选仓库，无状态记录仅来自备忘文件。
export function shareLocationTaskQueries(memoFile?: CoreOrgFileRef): CoreTaskQuery[] {
  const queries: CoreTaskQuery[] = [{ expression: 'has.address it.todo' }]
  if (memoFile) queries.push({ expression: 'has.address it.none', includeFiles: [memoFile] })
  return queries
}

export type TaskView = 'today' | 'planned' | 'waiting' | 'anytime' | 'someday' | 'memo' | 'logbook'

export function overviewTitle(view: TaskView): string {
  switch (view) {
    case 'today': return '今天'
    case 'planned': return '计划'
    case 'waiting': return '等待'
    case 'anytime': return '随时'
    case 'someday': return '某天'
    case 'memo': return '备忘'
    case 'logbook': return '日志簿'
  }
}

export function overviewTaskQuery(view: TaskView, file?: CoreOrgFileRef): CoreTaskQuery {
  let expression = ''
  switch (view) {
    case 'today': expression = '.it.done (s.le.today or d.le.today)'; break
    case 'planned': expression = '.it.done .is.habit ((s.ge.tomorrow d.ge.tomorrow) or (s.ge.tomorrow d.none) or (s.none d.ge.tomorrow))'; break
    case 'waiting': expression = 'i.wait o.priority .o.created'; break
    case 'anytime': expression = 'it.todo s.none d.none o.priority .o.created'; break
    case 'someday': return { expression: 'it.todo', includeFiles: file ? [file] : [] }
    case 'memo': return file ? memoRecordQuery(file) : { expression: '.o.modified' }
    case 'logbook': expression = 'it.done'; break
  }
  return { expression }
}

export function todayPriorityQuery(): CoreTaskQuery {
  const query = overviewTaskQuery('today')
  query.expression += ' o.priority'
  return query
}

export function todayAttentionQuery(): CoreTaskQuery {
  // 明天边界按实际规划日期匹配，习惯仅在计划日期已到时计入，排除提前预警。
  return { expression: 'it.todo ((is.habit s.lt.tomorrow) or d.lt.tomorrow)' }
}

// 分类与项目共用一个选择；项目由仓库和文件定位，避免跨仓库同名文件混入。
export function plannedRegionQuery(region: TaskRegionData | null): CoreQuery {
  const query = overviewTaskQuery('planned')
  if (region?.kind === 'category') {
    query.categories = [region.category]
  } else if (region?.kind === 'project') {
    query.includeFiles = [{ repoId: region.repoId, path: region.filePath }]
    return { type: 'task', query, repoIds: [region.repoId] }
  }
  return { type: 'task', query }
}
