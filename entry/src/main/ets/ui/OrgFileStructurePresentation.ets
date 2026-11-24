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
  private hasParentMoves: boolean = false

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
    const siblings = this.siblings(node.parent)
    if (to < 0 || to >= siblings.length) return false
    const remaining = siblings.filter(item => item.id !== node.id)
    return this.move(node, { parent: node.parent, after: remaining[to - 1]?.id ?? null })
  }

  move(node: OrgFileStructureNode, position: OrgFileStructureMove): boolean {
    const previous = this.siblings(node.parent)
    const from = previous.findIndex(item => item.id === node.id)
    const sameParent = node.parent === position.parent
    if (from < 0 || (sameParent && (previous[from - 1]?.id ?? null) === position.after)) return false
    const remaining = previous.slice()
    remaining.splice(from, 1)
    const destination = sameParent ? remaining : this.siblings(position.parent).slice()
    const anchor = destination.findIndex(item => item.id === position.after)
    if (position.after !== null && anchor < 0) return false
    const moved: OrgFileStructureNode = {
      id: node.id, row: node.row, parent: position.parent, title: node.title, titleParts: node.titleParts,
      task: node.task, taskPreview: node.taskPreview, hidden: node.hidden
    }
    destination.splice(anchor + 1, 0, moved)
    if (!sameParent) {
      this.setSiblings(node.parent, remaining)
      this.hasParentMoves = true
    }
    this.setSiblings(position.parent, destination)
    this.orderEdits.push({ type: 'move', ids: [node.id], parent: position.parent, after: position.after })
    if (!this.changed) {
      this.orderEdits.length = 0
      this.hasParentMoves = false
    } else if (!this.hasParentMoves && !this.changedParents.has(node.parent)) {
      // 跨父级操作依赖操作顺序。纯同级排序可以跳过已恢复初始顺序的分组。
      for (let index = this.orderEdits.length - 1; index >= 0; index--) {
        const edit = this.orderEdits[index]
        if (edit.type === 'move' && edit.parent === node.parent) this.orderEdits.splice(index, 1)
      }
    }
    return true
  }

  private setSiblings(parent: string | null, siblings: OrgFileStructureNode[]): void {
    this.orderedChildren.set(parent, siblings)
    const initial = this.initialChildren.get(parent) ?? []
    if (siblings.length === initial.length && siblings.every((item, index) => item.id === initial[index].id)) {
      this.changedParents.delete(parent)
    } else {
      this.changedParents.add(parent)
    }
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
export type OrgFileDropPlacement = 'before' | 'after' | 'child'

export interface OrgFileEditRow {
  row: string
  level: number
  parent: string | null
  task: boolean
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
  private readonly draft: ProjectStructureDraft
  private highlighted: string

  constructor(snapshot: OrgFileStructureSnapshot, row: string = '') {
    this.snapshot = snapshot
    this.draft = new ProjectStructureDraft(snapshot)
    this.highlighted = row
  }

  move(row: string, targetRow: string, placement: OrgFileDropPlacement): boolean {
    const nodes = this.draft.nodes
    const source = nodes.find(node => node.row === row)
    const target = nodes.find(node => node.row === targetRow)
    if (!source || !target) return false
    const position = this.draft.destination(target.id, placement, [source.id])
    if (!position || !this.draft.move(source, position)) return false
    this.highlighted = ''
    return true
  }

  edits(): CoreTaskStructureEdit[] { return this.draft.edits() }

  view(): OrgFileEditView {
    const levels = new Map<string, number>()
    const rows = this.draft.nodes.map((node): OrgFileEditRow => {
      const level = 1 + (node.parent === null ? 0 : levels.get(node.parent) ?? 0)
      levels.set(node.id, level)
      return { row: node.row, level, parent: node.parent, task: node.task,
        canReorder: node.parent !== null || this.draft.siblings(null).length > 1 }
    })
    return { active: true, changed: this.draft.changed, rows, highlighted: this.highlighted }
  }
}
