// 参考界面的浅色语义色与共用尺寸。
export class UiColor {
  static readonly surface: string = '#FFF8FF'
  static readonly container: string = '#F3EDF7'
  static readonly field: string = '#E7E0EC'
  static readonly primary: string = '#6750A4'
  static readonly selected: string = '#EADDFF'
  static readonly onSelected: string = '#21005D'
  static readonly text: string = '#1D1B20'
  static readonly secondary: string = '#49454F'
  static readonly outline: string = '#CAC4D0'
  static readonly error: string = '#B3261E'
  static readonly done: string = '#1B5E20'
}

export function dateLabel(value: string): string {
  const date = new Date(`${value.slice(0, 10)}T12:00:00`)
  if (isNaN(date.getTime())) return value
  const weekdays: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六']
  return `${date.getMonth() + 1}月${date.getDate()}日 ${weekdays[date.getDay()]}`
}

export function localDate(date: Date): string {
  return `${date.getFullYear()}-${(date.getMonth() + 1).toString().padStart(2, '0')}-${date.getDate().toString().padStart(2, '0')}`
}

export function repositoryName(path: string): string {
  const parts = path.split('/').filter((part: string) => part.length > 0)
  return parts.length > 0 ? parts[parts.length - 1] : '未设置目录'
}
