import { localizedText } from './LocalizedText'
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
  if (!input.repoId) return localizedText($r('app.string.text_please_select_the_repository'))
  if (!input.title.trim()) return localizedText($r('app.string.text_please_enter_the_title'))
  if (/[\r\n\u0000]/.test(input.title)) return localizedText($r('app.string.text_title_cannot_contain_line_breaks_or_control'))
  if (/[\r\n\u0000]/.test(input.projectName)) return localizedText($r('app.string.text_item_name_cannot_contain_line_breaks_or'))
  const path = input.fileName.trim() || input.title.trim()
  if (path.toLowerCase() === '.org') return localizedText($r('app.string.text_please_enter_a_filename'))
  if (path === '.' || path === '..' || /[\/\\\r\n\u0000]/.test(path)) return localizedText($r('app.string.text_file_name_cannot_contain_directory_separator_or'))
  if (/[\r\n\u0000]/.test(input.region)) return localizedText($r('app.string.text_category_name_cannot_contain_line_breaks_or'))
  return ''
}
