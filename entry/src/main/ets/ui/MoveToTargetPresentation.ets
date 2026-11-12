import { CoreRefileTarget } from '../services/NativeCoreService'
import { UiSize } from './Theme'

export interface RefileSection { key: string; kind: 'category' | 'project'; name: string; targets: CoreRefileTarget[] }

// 项目名与普通文件 CATEGORY 平级分组；每个 Core 目标及其快照身份均予以保留。
export function refileSections(targets: CoreRefileTarget[]): RefileSection[] {
  const groups = new Map<string, RefileSection>()
  for (const target of targets) {
    const project = target.projectName !== null
    const kind = project ? 'project' : 'category'
    const name = project ? target.projectName || '未命名项目' : target.category || ''
    const key = JSON.stringify([kind, project ? target.projectName : name])
    let section = groups.get(key)
    if (!section) { section = { key, kind, name, targets: [] }; groups.set(key, section) }
    section.targets.push(target)
  }
  const sections: RefileSection[] = []
  groups.forEach((section: RefileSection) => sections.push(section))
  return sections.sort((left: RefileSection, right: RefileSection): number => {
    if (!left.name) return right.name ? 1 : 0
    if (!right.name) return -1
    return left.name < right.name ? -1 : left.name > right.name ? 1 : left.key < right.key ? -1 : left.key > right.key ? 1 : 0
  })
}

// 以最多目标的分类计算高度，最多显示四行；小窗口为锚点和系统栏留出空间。
export function targetPopupHeight(sections: RefileSection[], availableHeight: number,
  loading: boolean = false, message: string = '', busy: boolean = false): number {
  let count = 0
  for (const section of sections) count = Math.max(count, section.targets.length)
  const body = loading ? 64 : count > 0 ? 40 + 8 + Math.min(4, count) * UiSize.taskRow : 80
  const height = 48 + 1 + 8 + body + (message ? 124 : 0) + (busy ? 40 : 0)
  return Math.min(height, Math.max(160, availableHeight - 104))
}
