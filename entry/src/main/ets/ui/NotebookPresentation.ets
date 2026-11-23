import { AppConfig } from '../models/OrgTask'
import { configuredFileTarget, FileTargetKind } from '../services/FileTargetService'
import { CoreOrgFileMetadata, CoreTaskStateCount } from '../services/NativeCoreService'
import { RegionOrder, orderedKeys, orderProjectKey, orderRegionKey } from './RegionOrderPresentation'

export function filePathLabel(path: string): string {
  // 只解码显示用的 UTF-8 字符，保留百分号编码的 ASCII 分隔符和字面百分号。
  return path.replace(/%[C-Fc-f][0-9A-Fa-f](?:%[89ABab][0-9A-Fa-f]){1,3}/g, (encoded: string): string => {
    try { return decodeURIComponent(encoded) } catch (_) { return encoded }
  })
}

export function fileTaskCount(file: CoreOrgFileMetadata): number {
  return file.taskStateCounts.reduce((total: number, item: CoreTaskStateCount): number => total + item.count, 0)
}

export function fileCompletedTaskCount(file: CoreOrgFileMetadata): number {
  return file.taskStateCounts.reduce((total: number, item: CoreTaskStateCount): number =>
    total + (item.category === 'Done' ? item.count : 0), 0)
}

export function fileTaskProgress(file: CoreOrgFileMetadata): string {
  return `${fileCompletedTaskCount(file)}/${fileTaskCount(file)}`
}

export interface ProjectSection {
  category: string
  files: CoreOrgFileMetadata[]
}

// 仅组织 Core 已筛选的项目结果；同名项目保持各自真实文件身份。
export function projectSections(files: CoreOrgFileMetadata[], order: RegionOrder | null = null): ProjectSection[] {
  const sections: ProjectSection[] = []
  for (const file of files) {
    const category = file.category || ''
    let section = sections.find((item: ProjectSection): boolean => item.category === category)
    if (!section) { section = { category, files: [] }; sections.push(section) }
    section.files.push(file)
  }
  const compareName = (left: string, right: string): number => left < right ? -1 : left > right ? 1 : 0
  const defaults = sections.filter(item => item.category.length > 0).sort((left, right) => compareName(left.category, right.category))
    .concat(sections.filter(item => item.category.length === 0))
  return orderedKeys(defaults.map(section => orderRegionKey(section.category)), order?.regions ?? []).map((key): ProjectSection => {
    const section = defaults.find(item => orderRegionKey(item.category) === key)!
    const projects = section.files.slice().sort((left, right) => compareName(left.project() || '', right.project() || '') ||
      compareName(orderProjectKey(left.repoId, left.path), orderProjectKey(right.repoId, right.path)))
    const projectKeys = orderedKeys(projects.map(file => orderProjectKey(file.repoId, file.path)),
      order?.projects.find(item => item.region === key)?.keys ?? [])
    return { category: section.category, files: projectKeys.map(id => projects.find(file => orderProjectKey(file.repoId, file.path) === id)!) }
  })
}

export function fileSizeLabel(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`
}

export function fileModifiedLabel(timestamp: number | null, compact: boolean = false, referenceTime: number = Date.now()): string {
  if (timestamp === null) return compact ? '时间未知' : '修改时间未知'
  const date = new Date(timestamp)
  if (isNaN(date.getTime())) return compact ? '时间未知' : '修改时间未知'
  const month = (date.getMonth() + 1).toString().padStart(2, '0')
  const day = date.getDate().toString().padStart(2, '0')
  const hour = date.getHours().toString().padStart(2, '0')
  const minute = date.getMinutes().toString().padStart(2, '0')
  if (compact) {
    return date.getFullYear() === new Date(referenceTime).getFullYear()
      ? `${month}-${day} ${hour}:${minute}` : `${date.getFullYear()}-${month}-${day}`
  }
  return `修改于 ${date.getFullYear()}-${month}-${day} ${hour}:${minute}`
}

export function fileUsageKinds(config: AppConfig, configId: string, path: string): FileTargetKind[] {
  if (!configId || !path) return []
  const kinds: FileTargetKind[] = ['inbox', 'someday', 'memo']
  return kinds.filter((kind: FileTargetKind): boolean => {
    const target = configuredFileTarget(config, kind)
    return target.repoId === configId && target.path === path
  })
}
