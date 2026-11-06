import { CoreTitleCount, CoreTitlePart } from '../services/NativeCoreService'

// 只消费 Core 的计数投影，不从标题文字推断 Org 语法。
export function titleCounts(parts: CoreTitlePart[]): CoreTitleCount[] {
  const result: CoreTitleCount[] = []
  parts.forEach((part: CoreTitlePart) => { if (part.count) result.push(part.count) })
  return result
}

export function titleCountLabel(count: CoreTitleCount): string {
  return count.completed === null || count.total === null ? '—/—' : `${count.completed}/${count.total}`
}

export function titleCountValue(count: CoreTitleCount): number {
  return count.total !== null && count.total > 0 && count.completed !== null ? count.completed / count.total * 100 : 0
}

export function titleCountDescription(count: CoreTitleCount): string {
  return count.total === null ? '尚无有效计数' : `已完成 ${count.completed} 项，共 ${count.total} 项`
}

export function titleCountsWidth(parts: CoreTitlePart[], budget: number = 0): number {
  const counts = titleCounts(parts)
  const width = counts.reduce((sum: number, count: CoreTitleCount): number => sum + 33 + titleCountLabel(count).length * 7.2, 0)
    + Math.max(0, counts.length - 1) * 6
  return budget > 0 && width > budget ? 14 : width
}
