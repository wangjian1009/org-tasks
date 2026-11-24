import { CoreTask, CoreTaskPath, CoreTaskStructureEdit, CoreTitlePart } from '../services/NativeCoreService'

export interface OrgFileStructureNode {
  id: string
  row: string
  parent: string | null
  title: string
  titleParts: CoreTitlePart[]
  task: boolean
  taskPreview?: CoreTask
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
      taskPreview: task.state ? task : undefined,
      hidden: !!task.state && matches !== null && !matches.has(task.id) }
  })
}

export function projectSiblings(nodes: OrgFileStructureNode[], parent: string | null): OrgFileStructureNode[] {
  return nodes.filter(node => node.parent === parent)
}

export class ProjectStructureDraft {
  readonly initial: OrgFileStructureSnapshot
  private readonly initialChildren: Map<string | null, OrgFileStructureNode[]>
  private readonly orderedChildren: Map<string | null, OrgFileStructureNode[]>
  private readonly orderEdits: CoreTaskStructureEdit[] = []
  private readonly changedParents: Set<string | null> = new Set()

  constructor(snapshot: OrgFileStructureSnapshot) {
    this.initial = snapshot
    this.initialChildren = this.children(snapshot.nodes)
    this.orderedChildren = new Map(this.initialChildren)
  }

  get changed(): boolean { return this.changedParents.size > 0 }

  get nodes(): OrgFileStructureNode[] {
    if (!this.changed) return this.initial.nodes
    const ordered: OrgFileStructureNode[] = []
    const visit = (parent: string | null): void => {
      for (const node of this.siblings(parent)) {
        ordered.push(node)
        visit(node.id)
      }
    }
    visit(null)
    return ordered
  }

  siblings(parent: string | null): OrgFileStructureNode[] { return this.orderedChildren.get(parent) ?? [] }

  reorder(node: OrgFileStructureNode, to: number): boolean {
    const siblings = this.siblings(node.parent).slice()
    const from = siblings.findIndex(item => item.id === node.id)
    if (from < 0 || to < 0 || to >= siblings.length || from === to) return false
    siblings.splice(from, 1)
    siblings.splice(to, 0, node)
    this.orderedChildren.set(node.parent, siblings)
    const initial = this.initialChildren.get(node.parent)!
    if (siblings.every((item, index) => item.id === initial[index].id)) {
      this.changedParents.delete(node.parent)
      // 已恢复初始顺序，此前该组的拖动无需提交。
      for (let index = this.orderEdits.length - 1; index >= 0; index--) {
        const edit = this.orderEdits[index]
        if (edit.type === 'move' && edit.parent === node.parent) this.orderEdits.splice(index, 1)
      }
    } else {
      this.changedParents.add(node.parent)
      this.orderEdits.push({ type: 'move', ids: [node.id], parent: node.parent, after: siblings[to - 1]?.id ?? null })
    }
    return true
  }

  edits(): CoreTaskStructureEdit[] { return this.orderEdits.slice() }

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
    const open = new Set<string>(expanded)
    const result: OrgFileStructureRow[] = []
    const text = query.trim().toLocaleLowerCase()
    const visit = (parent: string | null, depth: number, path: string): void => {
      for (const node of this.siblings(parent)) {
        const location = path ? `${path} › ${node.title}` : node.title
        const hasChildren = this.siblings(node.id).length > 0
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
  changed: boolean
  rows: OrgFileEditRow[]
  highlighted: string
}

export function projectEditIdle(): OrgFileEditView {
  return { active: false, changed: false, rows: [], highlighted: '' }
}

// 手柄操作只更新草稿，保存时将同一快照上的移动交给 Core。
export class OrgFileEditSession {
  readonly snapshot: OrgFileStructureSnapshot
  private readonly byRow: Map<string, OrgFileStructureNode>
  private readonly draft: ProjectStructureDraft
  private highlighted: string

  constructor(snapshot: OrgFileStructureSnapshot, row: string = '') {
    this.snapshot = snapshot
    this.draft = new ProjectStructureDraft(snapshot)
    this.byRow = new Map<string, OrgFileStructureNode>(snapshot.nodes.map(node => [node.row, node]))
    this.highlighted = row
  }

  reorder(row: string, sibling: string): boolean {
    const source = this.byRow.get(row)
    const target = this.byRow.get(sibling)
    if (!source || !target || source.parent !== target.parent) return false
    const index = this.draft.siblings(source.parent).findIndex(node => node.id === target.id)
    if (!this.draft.reorder(source, index)) return false
    this.highlighted = ''
    return true
  }

  edits(): CoreTaskStructureEdit[] { return this.draft.edits() }

  view(): OrgFileEditView {
    const levels = new Map<string, number>()
    const rows = this.draft.nodes.map((node): OrgFileEditRow => {
      const level = 1 + (node.parent === null ? 0 : levels.get(node.parent) ?? 0)
      levels.set(node.id, level)
      return { row: node.row, level, canReorder: this.draft.siblings(node.parent).length > 1 }
    })
    return { active: true, changed: this.draft.changed, rows, highlighted: this.highlighted }
  }
}
