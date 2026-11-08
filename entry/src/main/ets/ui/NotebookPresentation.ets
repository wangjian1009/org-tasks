import { AppConfig } from '../models/OrgTask'
import { configuredFileTarget, FileTargetKind } from '../services/FileTargetService'

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
