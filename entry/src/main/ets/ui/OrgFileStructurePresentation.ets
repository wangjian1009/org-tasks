import { CoreTask, CoreTaskPath, CoreTaskStructureEdit, CoreTitlePart } from '../services/NativeCoreService'

export interface OrgFileStructureNode {
  id: string
  row: string
  parent: string | null
  title: string
  titleParts: CoreTitlePart[]
  task: boolean
  hidden: boolean
}
export interface OrgFileStructureSnapshot {
  file: CoreTaskPath
  version: string
  title: string
  nodes: OrgFileStructureNode[]
  hasConflict: boolean
}
export interface OrgFileStructureRow {
  node: OrgFileStructureNode
  depth: number
  hasChildren: boolean
  path: string
}
export interface OrgFileStructureMove {
  parent: string | null
  after: string | null
}
export function projectStructureNodes(tasks: CoreTask[], key: (task: CoreTask) => string,
  matched: string[] | null): OrgFileStructureNode[] {
  const ancestors: CoreTask[] = []
  const matches = matched === null ? null : new Set<string>(matched)
  return tasks.map((task: CoreTask): OrgFileStructureNode => {
    while (ancestors.length && ancestors[ancestors.length - 1].level >= task.level) ancestors.pop()
    const parent = ancestors.length ? ancestors[ancestors.length - 1].id : null
    ancestors.push(task)
    return { id: task.id, row: key(task), parent, title: task.heading, titleParts: task.headingParts, task: !!task.state,
      hidden: !!task.state && matches !== null && !matches.has(task.id) }
  })
}

export function projectSiblings(nodes: OrgFileStructureNode[], parent: string | null): OrgFileStructureNode[] {
  return nodes.filter(node => node.parent === parent)
}

export function projectOrderMove(nodes: OrgFileStructureNode[], id: string, to: number): OrgFileStructureMove | undefined {
  const node = nodes.find(item => item.id === id)
  if (!node) return undefined
  const siblings = projectSiblings(nodes, node.parent)
  const from = siblings.findIndex(item => item.id === id)
  if (to < 0 || to >= siblings.length || from === to) return undefined
  siblings.splice(from, 1)
  return { parent: node.parent, after: to === 0 ? null : siblings[to - 1].id }
}

export class ProjectStructureDraft {
  readonly initial: OrgFileStructureSnapshot
  constructor(snapshot: OrgFileStructureSnapshot) { this.initial = snapshot }
  get nodes(): OrgFileStructureNode[] { return this.initial.nodes }

  private index(nodes: OrgFileStructureNode[] = this.nodes): Map<string, OrgFileStructureNode> {
    return new Map<string, OrgFileStructureNode>(nodes.map(node => [node.id, node]))
  }

  private children(nodes: OrgFileStructureNode[] = this.nodes): Map<string | null, OrgFileStructureNode[]> {
    const children = new Map<string | null, OrgFileStructureNode[]>()
    for (const node of nodes) {
      const siblings = children.get(node.parent)
      if (siblings) siblings.push(node)
      else children.set(node.parent, [node])
    }
    return children
  }

  path(id: string | null, nodes: OrgFileStructureNode[] = this.nodes): string {
    const byId = this.index(nodes)
    const parts: string[] = []
    let current = id === null ? undefined : byId.get(id)
    while (current) {
      parts.push(current.title)
      current = current.parent === null ? undefined : byId.get(current.parent)
    }
    return parts.reverse().join(' › ') || this.initial.title
  }

  ancestors(id: string): string[] {
    const byId = this.index()
    const result: string[] = []
    let current = byId.get(id)
    while (current?.parent !== null && current?.parent !== undefined) {
      result.push(current.parent)
      current = byId.get(current.parent)
    }
    return result
  }

  covered(id: string, ids: string[]): boolean {
    return ids.includes(id) || this.ancestors(id).some(parent => ids.includes(parent))
  }

  rows(expanded: string[], query: string): OrgFileStructureRow[] {
    const children = this.children()
    const open = new Set<string>(expanded)
    const result: OrgFileStructureRow[] = []
    const text = query.trim().toLocaleLowerCase()
    const visit = (parent: string | null, depth: number, path: string): void => {
      for (const node of children.get(parent) ?? []) {
        const location = path ? `${path} › ${node.title}` : node.title
        const hasChildren = !!children.get(node.id)?.length
        if (!text || location.toLocaleLowerCase().includes(text)) result.push({ node, depth, hasChildren, path: location })
        if (hasChildren && (text || open.has(node.id))) visit(node.id, depth + 1, location)
      }
    }
    visit(null, 0, '')
    return result
  }

  destination(target: string | null, placement: string, selected: string[]): OrgFileStructureMove | undefined {
    const node = this.nodes.find(item => item.id === target)
    if (target === null) {
      const remaining = projectSiblings(this.nodes, null).filter(item => !selected.includes(item.id))
      return { parent: null, after: placement === 'last' && remaining.length ? remaining[remaining.length - 1].id : null }
    }
    if (!node || this.covered(target, selected)) return undefined
    if (placement === 'child') return { parent: node.id, after: null }
    if (placement === 'after') return { parent: node.parent, after: node.id }
    const remaining = projectSiblings(this.nodes, node.parent).filter(item => !selected.includes(item.id))
    const index = remaining.findIndex(item => item.id === node.id)
    return { parent: node.parent, after: index > 0 ? remaining[index - 1].id : null }
  }

}

export type OrgFilePlacement = 'first' | 'last' | 'before' | 'after' | 'child'

export interface OrgFileEditRow {
  row: string
  level: number
  canReorder: boolean
}

export interface OrgFileEditView {
  active: boolean
  rows: OrgFileEditRow[]
  highlighted: string
}

export function projectEditIdle(): OrgFileEditView {
  return { active: false, rows: [], highlighted: '' }
}

// 会话保留一份已确认的结构快照，每次移动由 Core 验证并提交。
export class OrgFileEditSession {
  readonly snapshot: OrgFileStructureSnapshot
  private readonly byRow: Map<string, OrgFileStructureNode>
  private readonly highlighted: string

  constructor(snapshot: OrgFileStructureSnapshot, row: string = '') {
    this.snapshot = snapshot
    this.byRow = new Map<string, OrgFileStructureNode>(snapshot.nodes.map(node => [node.row, node]))
    this.highlighted = row
  }

  reorder(row: string, sibling: string): CoreTaskStructureEdit | undefined {
    const source = this.byRow.get(row)
    const target = this.byRow.get(sibling)
    if (!source || !target || source.parent !== target.parent) return undefined
    const index = projectSiblings(this.snapshot.nodes, source.parent).findIndex(node => node.id === target.id)
    const destination = projectOrderMove(this.snapshot.nodes, source.id, index)
    return destination ? { type: 'move', ids: [source.id], parent: destination.parent, after: destination.after } : undefined
  }

  view(): OrgFileEditView {
    const levels = new Map<string, number>()
    const siblingCounts = new Map<string | null, number>()
    for (const node of this.snapshot.nodes) {
      siblingCounts.set(node.parent, (siblingCounts.get(node.parent) ?? 0) + 1)
    }
    const rows = this.snapshot.nodes.map((node): OrgFileEditRow => {
      const level = 1 + (node.parent === null ? 0 : levels.get(node.parent) ?? 0)
      levels.set(node.id, level)
      return { row: node.row, level, canReorder: (siblingCounts.get(node.parent) ?? 0) > 1 }
    })
    return { active: true, rows, highlighted: this.highlighted }
  }
}
