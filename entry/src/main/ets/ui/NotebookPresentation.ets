import { AppConfig } from '../models/OrgTask'
import { configuredFileTarget, FileTargetKind } from '../services/FileTargetService'
import { CoreOrgFileMetadata, CoreTaskStateCount } from '../services/NativeCoreService'

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
export function projectSections(files: CoreOrgFileMetadata[]): ProjectSection[] {
  const sections: ProjectSection[] = []
  for (const file of files) {
    const category = file.category || ''
    let section = sections.find((item: ProjectSection): boolean => item.category === category)
    if (!section) { section = { category, files: [] }; sections.push(section) }
    section.files.push(file)
  }
  return sections.filter((item: ProjectSection): boolean => item.category.length > 0)
    .concat(sections.filter((item: ProjectSection): boolean => item.category.length === 0))
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
