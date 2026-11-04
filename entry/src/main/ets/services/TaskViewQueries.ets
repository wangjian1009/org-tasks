import { CoreTaskQuery } from './NativeCoreService'

// 只组装界面所需的查询请求；任务筛选、完成类型与父子关系均由 core 求值。
export function categoryTaskQuery(inboxFile: string, categories: (string | null)[] = []): CoreTaskQuery {
  return {
    categories,
    excludedFiles: categories.length > 0 ? [inboxFile] : [],
    includeDone: false,
    includeComposeTasks: true
  }
}

export function categoryNavigationQuery(inboxFile: string): CoreTaskQuery {
  return { excludedFiles: [inboxFile], includeDone: false, includeComposeTasks: true }
}

export function inboxRecordQuery(inboxFile: string): CoreTaskQuery {
  const path = inboxFile.replace(/\\/g, '\\\\').replace(/"/g, '\\"')
  return { expression: `b."${path}"`, includeDone: true, includeComposeTasks: true }
}
