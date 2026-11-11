import { RepoConfig } from '../models/OrgTask'

// 与侧边栏统一的全局深色语义色。
export class UiColor {
  static readonly drawer: string = '#2D2C2B'
  static readonly drawerSelected: string = '#3A3E3F'
  static readonly drawerText: string = '#D8D8D8'
  static readonly drawerSecondary: string = '#AEACA9'
  static readonly drawerOutline: string = '#4B4A48'
  static readonly overdueBadge: string = '#E73157'
  static readonly surface: string = '#2D2C2B'
  static readonly projectBlock: string = '#313432'
  static readonly projectOutline: string = '#424843'
  static readonly projectLabel: string = '#9DA69F'
  static readonly taskCard: string = '#3A3938'
  static readonly notificationCard: string = '#373635'
  static readonly deadline: string = '#FF3869'
  static readonly container: string = '#343635'
  static readonly field: string = '#3A3E3F'
  static readonly primary: string = '#5AC4B9'
  static readonly onPrimary: string = '#123D37'
  static readonly selected: string = '#3A3E3F'
  static readonly onSelected: string = '#E6E6E6'
  static readonly text: string = '#D8D8D8'
  static readonly secondary: string = '#AEACA9'
  static readonly disabled: string = '#92938F'
  static readonly divider: string = '#494B48'
  static readonly outline: string = '#4B4A48'
  static readonly error: string = '#FF7592'
  static readonly conflictBadge: string = '#55313B'
  static readonly warning: string = '#F2C96D'
  static readonly done: string = '#65CD7B'
  static readonly selection: string = '#4A8DF6'
  static readonly selectionTint: string = '#304765'
  static readonly menu: string = '#454948'
  static readonly menuOutline: string = '#565B59'
  static readonly dialog: string = '#262B2D'
}

export class UiSize {
  static readonly taskFont: number = 16
  static readonly taskRow: number = 44
  static readonly drawerFont: number = 16
  static readonly drawerRow: number = 44
  static readonly drawerIcon: number = 22
  static readonly menuFont: number = 16
  static readonly menuIcon: number = 16
  static readonly menuPadding: number = 12
  static readonly menuGap: number = 8
  static readonly menuRow: number = 44
  static readonly menuRadius: number = 10
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

export function repositoryLabel(repo: RepoConfig | undefined): string {
  return repo ? (repo.name || '').trim() || repositoryName(repo.rootDirectory) : '未设置目录'
}
