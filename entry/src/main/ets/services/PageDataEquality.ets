import { CoreTask, CoreOrgFileMetadata } from './NativeCoreService'
import { taskRecord, metadataRecord } from './PageDataSnapshot'

// 比较只读数据，不序列化页面；共享引用立即返回，版本等编辑上下文不作为显示变化。
export function samePageValue(left: Object | null | undefined, right: Object | null | undefined): boolean {
  if (left === right) return true
  if (left === null || right === null || left === undefined || right === undefined ||
    typeof left !== 'object' || typeof right !== 'object') return false
  if (Array.isArray(left) || Array.isArray(right)) {
    if (!Array.isArray(left) || !Array.isArray(right)) return false
    const a = left as Object[]; const b = right as Object[]
    return a.length === b.length && a.every((value: Object, index: number): boolean => samePageValue(value, b[index]))
  }
  const a = left as Record<string, Object>; const b = right as Record<string, Object>
  const keys = Object.keys(a)
  const otherKeys = Object.keys(b)
  return keys.length === otherKeys.length && keys.every((key: string): boolean =>
    otherKeys.includes(key) && samePageValue(a[key], b[key]))
}

export function samePageTask(left: CoreTask, right: CoreTask): boolean {
  if (left === right) return true
  const a = taskRecord(left); const b = taskRecord(right)
  a.value.fileVersion = ''; b.value.fileVersion = ''
  // 排序键属于容器结构；来源仍推进快照，但单条控件不因位置标量变化而重绘。
  a.value.orderKey = undefined; b.value.orderKey = undefined
  // 原文供编辑定位使用；阅读内容已由 bodyHtml、editContent 等字段表达。
  a.value.body = ''; b.value.body = ''
  return samePageValue(a, b)
}

export function samePageMetadata(left: CoreOrgFileMetadata, right: CoreOrgFileMetadata): boolean {
  return left === right || samePageValue(metadataRecord(left), metadataRecord(right))
}
