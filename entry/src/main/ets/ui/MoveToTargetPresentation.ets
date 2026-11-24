import { CoreRefileTarget, CoreTaskPath } from '../services/NativeCoreService'
import { DEFAULT_TASK_CATEGORY } from '../models/RepositoryDefaults'


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

// 历史身份排除源位置与文件版本，每次匹配最新目标快照。
export function refilePathKey(path: CoreTaskPath): string {
  return JSON.stringify([path.repoId, path.file, path.titles, path.occurrence ?? 1])
}

export function refileTargetKey(target: CoreRefileTarget): string {
  return refilePathKey(target.fullPath)
}

export function refileTargetTitle(target: CoreRefileTarget): string {
  if (!target.fullPath.titles.length) {
    return target.projectName === null ? DEFAULT_TASK_CATEGORY : target.projectName || '未命名项目'
  }
  return target.titleParts.map((part): string => part.text).join('').trim() || '未命名位置'
}

export interface RefileRow {
  key: string
  target: CoreRefileTarget
  title: string
  context: string
  searchText: string
}

interface RefileRowIdentity {
  pathLabel: string
  title: string
  repoLabel: string
  target: CoreRefileTarget
}

export function refileRows(sections: RefileSection[], repositoryNames: Map<string, string>): RefileRow[] {
  const entries: RefileRowIdentity[] = []
  const repositories = new Map<string, Set<string>>()
  const occurrences = new Map<string, number>()
  for (const section of sections) {
    for (const target of section.targets) {
      const title = refileTargetTitle(target)
      const pathLabel = [target.path, ...target.headingPath.slice(0, -1)].join(' / ')
      const identity = JSON.stringify([title, pathLabel])
      const repos = repositories.get(identity) ?? new Set<string>()
      repos.add(target.repoId)
      repositories.set(identity, repos)
      const inRepository = JSON.stringify([identity, target.repoId])
      occurrences.set(inRepository, (occurrences.get(inRepository) ?? 0) + 1)
      const repoLabel = repositoryNames.get(target.repoId) || target.repoId
      entries.push({ pathLabel, title, repoLabel, target })
    }
  }
  const nameCounts = new Map<string, number>()
  repositoryNames.forEach((name: string): void => { nameCounts.set(name, (nameCounts.get(name) ?? 0) + 1) })
  const ordinals = new Map<string, number>()
  return entries.map((entry: RefileRowIdentity): RefileRow => {
    const target = entry.target
    const identity = JSON.stringify([entry.title, entry.pathLabel])
    const inRepository = JSON.stringify([identity, target.repoId])
    const rank = (ordinals.get(inRepository) ?? 0) + 1
    ordinals.set(inRepository, rank)
    const repoLabel = (nameCounts.get(entry.repoLabel) ?? 0) > 1 ?
      entry.repoLabel + ' (' + target.repoId + ')' : entry.repoLabel
    const showRepository = (repositories.get(identity)?.size ?? 0) > 1 ||
      (!target.fullPath.titles.length && target.projectName === null)
    const parts = showRepository ? [repoLabel, entry.pathLabel] : [entry.pathLabel]
    if ((occurrences.get(inRepository) ?? 0) > 1) parts.push('位置 ' + rank)
    return {
      key: refileTargetKey(target), target, title: entry.title, context: parts.join(' / '),
      searchText: [entry.title, target.projectName ?? '', target.category || '未分类', entry.pathLabel,
        target.headingPath[target.headingPath.length - 1] ?? '', entry.repoLabel].join(' ').toLowerCase()
    }
  })
}

export function searchRefileRows(rows: RefileRow[], query: string): RefileRow[] {
  const terms = query.trim().toLowerCase().split(/\s+/)
  return rows.filter((row: RefileRow): boolean => terms.every((term: string): boolean => row.searchText.includes(term)))
}

export function recentRefileRows(rows: RefileRow[], recent: string[]): RefileRow[] {
  const byKey = new Map<string, RefileRow>()
  rows.forEach((row: RefileRow): void => { byKey.set(row.key, row) })
  const result: RefileRow[] = []
  for (const key of recent) {
    const row = byKey.get(key)
    if (row) result.push(row)
    if (result.length === 4) break
  }
  return result
}
