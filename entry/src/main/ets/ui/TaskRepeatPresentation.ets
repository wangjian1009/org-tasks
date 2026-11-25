import { CoreTaskRepeatRule, CoreTaskRepeatUnit, CoreTaskModification } from '../services/NativeCoreService'
import { localizedText } from './LocalizedText'

export const repeatUnits: CoreTaskRepeatUnit[] = ['hour', 'day', 'week', 'month', 'year']
export const repeatUnitLabels: Resource[] = [
  $r('app.string.repeat_hour'), $r('app.string.repeat_day'), $r('app.string.repeat_week'),
  $r('app.string.repeat_month'), $r('app.string.repeat_year')
]
const repeatIntervals: Resource[] = [
  $r('app.string.repeat_hours_interval'), $r('app.string.repeat_days_interval'), $r('app.string.repeat_weeks_interval'),
  $r('app.string.repeat_months_interval'), $r('app.string.repeat_years_interval')
]

export function repeatSummary(rule: CoreTaskRepeatRule | null | undefined): string {
  if (!rule) return localizedText($r('app.string.repeat_none'))
  const interval = localizedText(repeatIntervals[repeatUnits.indexOf(rule.unit)], String(rule.interval))
  if (rule.mode === 'afterCompletion') return localizedText($r('app.string.repeat_after_completion'), interval)
  const summary = localizedText($r('app.string.repeat_every'), interval)
  return rule.mode === 'catchUp' ? `${summary} · ${localizedText($r('app.string.repeat_skip_past'))}` : summary
}

// 只组装 Core 的日期与规则字段，不生成或解析 Org 时间戳。
export function repeatModifications(deadline: boolean, originalDate: string, date: string,
  rule: CoreTaskRepeatRule | null): CoreTaskModification[] {
  const changes: CoreTaskModification[] = []
  if (rule && date !== originalDate) changes.push({ field: deadline ? 'DEADLINE' : 'SCHEDULE', value: { date } })
  changes.push({ field: deadline ? 'DEADLINE_REPEAT' : 'SCHEDULE_REPEAT', value: rule })
  return changes
}
