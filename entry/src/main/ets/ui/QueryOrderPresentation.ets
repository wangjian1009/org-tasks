import { QueryOrderPart } from 'liborg_tasks_harmony.so'

// 仅比较 Core 提供的排序标量，不在宿主计算查询排序规则。
interface OrderedRecord { readonly orderKey?: QueryOrderPart[] }
// 键与方向均由 Core 给出；这里只比较标量，不解释表达式或领域字段。
export function compareRecords(left: OrderedRecord, right: OrderedRecord): number {
  if (!left.orderKey || !right.orderKey) return 0
  for (let index = 0; index < Math.min(left.orderKey.length, right.orderKey.length); index++) {
    const a = left.orderKey[index]; const b = right.orderKey[index]
    if (a.value === null && b.value === null) continue
    if (a.value === null || b.value === null) {
      const value: number = a.value === null ? -1 : 1
      if (a.missingLast) return -value
      return a.descending ? -value : value
    }
    let value: number = 0
    if (typeof a.value === 'number' && typeof b.value === 'number') value = a.value < b.value ? -1 : a.value > b.value ? 1 : 0
    if (typeof a.value === 'string' && typeof b.value === 'string') value = a.value < b.value ? -1 : a.value > b.value ? 1 : 0
    if (value) return a.descending ? -value : value
  }
  return 0
}
