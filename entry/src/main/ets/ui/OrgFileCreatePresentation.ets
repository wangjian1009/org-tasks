export interface OrgFileRepositoryOption {
  repoId: string
  name: string
  regions: string[]
}

export interface OrgFileCreateInput {
  repoId: string
  region: string
  title: string
  projectName: string
  fileName: string
}
export interface OrgFileRegionDraft { repoId: string; name: string }

export function orgFileName(name: string): string {
  const trimmed = name.trim()
  return trimmed.toLowerCase().endsWith('.org') ? `${trimmed.slice(0, -4)}.org` : `${trimmed}.org`
}

export function orgFileInputError(input: OrgFileCreateInput): string {
  if (!input.repoId) return '请选择仓库'
  if (!input.title.trim()) return '请输入标题'
  if (/[\r\n\u0000]/.test(input.title)) return '标题不能包含换行或控制字符'
  if (/[\r\n\u0000]/.test(input.projectName)) return '项目名称不能包含换行或控制字符'
  const path = input.fileName.trim() || input.title.trim()
  if (path.toLowerCase() === '.org') return '请输入文件名'
  if (path === '.' || path === '..' || /[\/\\\r\n\u0000]/.test(path)) return '文件名不能包含目录分隔符或换行'
  if (/[\r\n\u0000]/.test(input.region)) return '分类名称不能包含换行或控制字符'
  return ''
}
