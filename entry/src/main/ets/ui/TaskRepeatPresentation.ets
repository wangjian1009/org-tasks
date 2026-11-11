import { CoreTaskRepeatRule, CoreTaskRepeatUnit, CoreTaskModification } from '../services/NativeCoreService'

export const repeatUnits: CoreTaskRepeatUnit[] = ['hour', 'day', 'week', 'month', 'year']
export const repeatUnitLabels: string[] = ['小时', '天', '周', '月', '年']

export function repeatSummary(rule: CoreTaskRepeatRule | null | undefined): string {
  if (!rule) return '不重复'
  const interval = `${rule.interval} ${repeatUnitLabels[repeatUnits.indexOf(rule.unit)]}`
  if (rule.mode === 'afterCompletion') return `完成 ${interval}后重复`
  return `每 ${interval}${rule.mode === 'catchUp' ? ' · 跳过已错过的日期' : ''}`
}

// 只组装 Core 的日期与规则字段，不生成或解析 Org 时间戳。
export function repeatModifications(deadline: boolean, originalDate: string, date: string,
  rule: CoreTaskRepeatRule | null): CoreTaskModification[] {
  const changes: CoreTaskModification[] = []
  if (rule && date !== originalDate) changes.push({ field: deadline ? 'DEADLINE_DATE' : 'SCHEDULE_DATE', value: date })
  changes.push({ field: deadline ? 'DEADLINE_REPEAT' : 'SCHEDULE_REPEAT', value: rule })
  return changes
}
