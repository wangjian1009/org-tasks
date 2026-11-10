import { CoreTaskQuery } from './NativeCoreService'

// 只组装界面所需的查询请求；任务筛选、完成类型与父子关系均由 core 求值。
export function inboxRecordQuery(inboxFile: string): CoreTaskQuery {
  const path = inboxFile.replace(/\\/g, '\\\\').replace(/"/g, '\\"')
  return { expression: `b."${path}"`, includeDone: true, includeComposeTasks: true }
}

export function memoRecordQuery(memoFile: string): CoreTaskQuery {
  return { expression: `${inboxRecordQuery(memoFile).expression} .o.modified`, includeDone: true, includeComposeTasks: true }
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
    case 'planned': expression = '(s.ge.tomorrow d.ge.tomorrow) or (s.ge.tomorrow d.none) or (s.none d.ge.tomorrow)'; break
    case 'anytime': expression = 'it.todo s.none d.none'; break
    case 'someday': return { expression: inboxRecordQuery(somedayFile).expression, includeDone: false, includeComposeTasks: true }
    case 'memo': return memoRecordQuery(memoFile)
    case 'logbook': expression = 'it.done'; break
  }
  return { expression, includeDone: view === 'logbook', includeComposeTasks: true }
}

export function overdueTaskQuery(): CoreTaskQuery {
  return { expression: '(s.le.yesterday or d.le.yesterday)', includeDone: false, includeComposeTasks: true }
}
