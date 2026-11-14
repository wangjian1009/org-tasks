import { CoreRefileTarget } from '../services/NativeCoreService'

export interface RefileSection { key: string; kind: 'category' | 'project'; name: string; targets: CoreRefileTarget[] }

// 项目名与普通文件 CATEGORY 平级分组；每个 Core 目标及其快照身份均予以保留。
export function refileSections(targets: CoreRefileTarget[]): RefileSection[] {
  const groups = new Map<string, RefileSection>()
  for (const target of targets) {
    const project = target.projectName !== null
    const kind = project ? 'project' : 'category'
    const name = project ? target.projectName || '未命名项目' : target.category || ''
    const key = JSON.stringify(project ? [kind, target.repoId, target.path] : [kind, name])
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

// 历史身份排除源位置与文件版本；每次使用重新查询的完整目标快照。
export function refileTargetKey(target: CoreRefileTarget): string {
  return JSON.stringify([target.repoId, target.path, target.fullPath.titles, target.fullPath.occurrence ?? 1])
}

export function refileTargetTitle(target: CoreRefileTarget): string {
  if (target.fullPath.titles.length === 0) return '项目开头'
  return target.titleParts.map((part): string => part.text).join('').trim() || '未命名位置'
}

export function recentRefileSections(sections: RefileSection[], recent: string[]): RefileSection[] {
  const rank = (target: CoreRefileTarget): number => {
    const index = recent.indexOf(refileTargetKey(target))
    return index < 0 ? recent.length : index
  }
  const result = sections.map((section: RefileSection): RefileSection => ({
    key: section.key, kind: section.kind, name: section.name,
    targets: section.targets.slice().sort((a: CoreRefileTarget, b: CoreRefileTarget): number => rank(a) - rank(b))
  }))
  return result.sort((a: RefileSection, b: RefileSection): number => {
    const first = (section: RefileSection): number => section.targets.reduce(
      (value: number, target: CoreRefileTarget): number => Math.min(value, rank(target)), recent.length)
    return first(a) - first(b)
  })
}
