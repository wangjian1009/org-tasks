export interface ProjectRepositoryOption {
  repoId: string
  name: string
  regions: string[]
}

export interface ProjectLocation { repoId: string; region: string }
export interface ProjectRegionDraft { repoId: string; name: string }

export function projectFileName(name: string): string {
  const trimmed = name.trim()
  return trimmed.toLowerCase().endsWith('.org') ? `${trimmed.slice(0, -4)}.org` : `${trimmed}.org`
}

export function projectInputError(repoId: string, name: string, fileName: string, region: string = ''): string {
  if (!repoId) return '请选择存储库'
  if (!name.trim()) return '请输入项目名'
  if (/[\r\n]/.test(name)) return '项目名不能包含换行'
  const path = fileName.trim()
  if (!path || path === '.org') return '请输入文件名'
  if (path === '.' || path === '..' || /[\/\\\r\n\u0000]/.test(path)) return '文件名不能包含目录分隔符或换行'
  if (/[\r\n\u0000]/.test(region)) return 'Region 名称不能包含换行或控制字符'
  return ''
}
