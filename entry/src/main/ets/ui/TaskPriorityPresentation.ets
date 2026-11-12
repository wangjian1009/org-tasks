import { CoreTaskPriority, CorePeriodCategory } from '../services/NativeCoreService'

// 分类来自 Core；字母仅用于显示，不参与颜色或最高分级计算。
export function priorityColor(category: CorePeriodCategory | null | undefined): string {
  switch (category) {
    case 'Hight': return '#F2C96D'
    case 'Middle': return '#78CEC4'
    case 'Low': return '#C1BFBC'
    default: return '#AEACA9'
  }
}
export function priorityBackground(category: CorePeriodCategory | null | undefined): string {
  switch (category) {
    case 'Hight': return '#4A4435'
    case 'Middle': return '#304A45'
    default: return '#454443'
  }
}
export function priorityLabel(priority: CoreTaskPriority | null): string {
  if (!priority) return '无优先级'
  const category = priority.category === 'Hight' ? '最重要' : priority.category === 'Middle' ? '中等' : priority.category === 'Low' ? '较低' : '未分类'
  return `优先级 ${priority.name}，${category}`
}
