import { CoreTask, CoreTaskPath, CoreTaskStructureEdit } from '../services/NativeCoreService'

export interface ProjectStructureNode {
  id: string
  row: string
  parent: string | null
  title: string
  task: boolean
  hidden: boolean
}
export interface ProjectStructureSnapshot {
  file: CoreTaskPath
  version: string
  title: string
  nodes: ProjectStructureNode[]
  hasConflict: boolean
}
export interface ProjectStructureRow {
  node: ProjectStructureNode
  depth: number
  hasChildren: boolean
  path: string
}
export interface ProjectStructureMove {
  parent: string | null
  after: string | null
}
export interface ProjectStructureChange {
  id: string
  title: string
  parent: string | null
  parentPath: string
  before: string
  after: string
  moved: boolean
}
interface StructureStep {
  nodes: ProjectStructureNode[]
  edit: CoreTaskStructureEdit
}

export function projectStructureNodes(tasks: CoreTask[], key: (task: CoreTask) => string,
  matched: string[] | null): ProjectStructureNode[] {
  const ancestors: CoreTask[] = []
  const matches = matched === null ? null : new Set<string>(matched)
  return tasks.map((task: CoreTask): ProjectStructureNode => {
    while (ancestors.length && ancestors[ancestors.length - 1].level >= task.level) ancestors.pop()
    const parent = ancestors.length ? ancestors[ancestors.length - 1].id : null
    ancestors.push(task)
    return { id: task.id, row: key(task), parent, title: task.heading, task: !!task.state,
      hidden: !!task.state && matches !== null && !matches.has(task.id) }
  })
}

export function projectSiblings(nodes: ProjectStructureNode[], parent: string | null): ProjectStructureNode[] {
  return nodes.filter(node => node.parent === parent)
}

export function projectOrderMove(nodes: ProjectStructureNode[], id: string, to: number): ProjectStructureMove | undefined {
  const node = nodes.find(item => item.id === id)
  if (!node) return undefined
  const siblings = projectSiblings(nodes, node.parent)
  const from = siblings.findIndex(item => item.id === id)
  if (to < 0 || to >= siblings.length || from === to) return undefined
  siblings.splice(from, 1)
  return { parent: node.parent, after: to === 0 ? null : siblings[to - 1].id }
}

export class ProjectStructureDraft {
  readonly initial: ProjectStructureSnapshot
  private steps: StructureStep[] = []

  constructor(snapshot: ProjectStructureSnapshot) { this.initial = snapshot }
  get nodes(): ProjectStructureNode[] { return this.steps.length ? this.steps[this.steps.length - 1].nodes : this.initial.nodes }
  get edits(): CoreTaskStructureEdit[] { return this.steps.map(step => step.edit) }
  get canUndo(): boolean { return this.steps.length > 0 }
  undo(): void { this.steps.pop() }

  private index(nodes: ProjectStructureNode[] = this.nodes): Map<string, ProjectStructureNode> {
    return new Map<string, ProjectStructureNode>(nodes.map(node => [node.id, node]))
  }

  private children(nodes: ProjectStructureNode[] = this.nodes): Map<string | null, ProjectStructureNode[]> {
    const children = new Map<string | null, ProjectStructureNode[]>()
    for (const node of nodes) {
      const siblings = children.get(node.parent)
      if (siblings) siblings.push(node)
      else children.set(node.parent, [node])
    }
    return children
  }

  path(id: string | null, nodes: ProjectStructureNode[] = this.nodes): string {
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

  rows(expanded: string[], query: string): ProjectStructureRow[] {
    const children = this.children()
    const open = new Set<string>(expanded)
    const result: ProjectStructureRow[] = []
    const text = query.trim().toLocaleLowerCase()
    const visit = (parent: string | null, depth: number, path: string): void => {
      for (const node of children.get(parent) ?? []) {
        const location = path ? `${path} › ${node.title}` : node.title
        const hasChildren = !!children.get(node.id)?.length
        if (!text || node.title.toLocaleLowerCase().includes(text)) result.push({ node, depth, hasChildren, path: location })
        if (hasChildren && (text || open.has(node.id))) visit(node.id, depth + 1, location)
      }
    }
    visit(null, 0, '')
    return result
  }

  rename(id: string, title: string): void {
    const current = this.nodes.find(node => node.id === id)
    if (!current || current.title === title) return
    const changed: ProjectStructureNode = { id, row: current.row, parent: current.parent, title, task: current.task, hidden: current.hidden }
    this.steps.push({ nodes: this.nodes.map(node => node.id === id ? changed : node), edit: { type: 'rename', id, title } })
  }

  destination(target: string | null, placement: string, selected: string[]): ProjectStructureMove | undefined {
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

  move(ids: string[], destination: ProjectStructureMove): boolean {
    const selected = new Set<string>(ids)
    const children = this.children()
    const ordered = this.rows(this.nodes.map(node => node.id), '').map(item => item.node).filter(node => selected.has(node.id))
    const previous = children.get(destination.parent) ?? []
    const siblings = previous.filter(node => !selected.has(node.id))
    const index = destination.after === null ? 0 : siblings.findIndex(node => node.id === destination.after) + 1
    if (!ordered.length || (destination.after !== null && index === 0)) return false
    const moved = ordered.map((node): ProjectStructureNode => ({
      id: node.id, row: node.row, title: node.title, parent: destination.parent, task: node.task, hidden: node.hidden
    }))
    siblings.splice(index, 0, ...moved)
    if (siblings.length === previous.length && siblings.every((node, index) => node.id === previous[index].id)) return false
    const other = this.nodes.filter(node => !selected.has(node.id) && node.parent !== destination.parent)
    this.steps.push({ nodes: other.concat(siblings), edit: { type: 'move', ids: moved.map(node => node.id),
      parent: destination.parent, after: destination.after } })
    return true
  }

  changes(): ProjectStructureChange[] {
    const original = this.index(this.initial.nodes)
    const originalChildren = this.children(this.initial.nodes)
    const currentChildren = this.children()
    const edited = new Set<string>()
    for (const step of this.steps) {
      if (step.edit.type === 'move') step.edit.ids.forEach(id => edited.add(id))
      else edited.add(step.edit.id)
    }
    const changes: ProjectStructureChange[] = []
    for (const node of this.nodes) {
      if (!edited.has(node.id)) continue
      const before = original.get(node.id)
      if (!before) continue
      const oldOrder = (originalChildren.get(node.parent) ?? []).filter(item => item.id !== node.id).map(item => item.id)
      const siblings = currentChildren.get(node.parent) ?? []
      const oldSiblings = originalChildren.get(node.parent) ?? []
      const originalPeers = new Set<string>(oldOrder)
      const currentPeers = new Set<string>(siblings.map(item => item.id))
      const preceding = siblings.slice(0, siblings.findIndex(item => item.id === node.id))
        .filter(item => originalPeers.has(item.id)).map(item => item.id)
      const oldPreceding = oldSiblings.slice(0, oldSiblings.findIndex(item => item.id === node.id))
        .filter(item => currentPeers.has(item.id)).map(item => item.id)
      const moved = before.parent !== node.parent || JSON.stringify(preceding) !== JSON.stringify(oldPreceding)
      if (moved || before.title !== node.title) {
        const afterIndex = siblings.findIndex(item => item.id === node.id)
        const previous = afterIndex > 0 ? siblings[afterIndex - 1].title : ''
        changes.push({ id: node.id, title: node.title, parent: node.parent, parentPath: this.path(node.parent),
          before: this.path(before.id, this.initial.nodes),
          after: previous ? `放在「${previous}」之后` : '首位', moved })
      }
    }
    return changes
  }
}

export type ProjectEditPhase = 'idle' | 'select' | 'target' | 'review'
export type ProjectPlacement = 'first' | 'last' | 'before' | 'after' | 'child'

export interface ProjectEditRow {
  row: string
  title: string
  level: number
  selected: number
  covered: boolean
  children: boolean
}

export interface ProjectEditView {
  phase: ProjectEditPhase
  refactoring: boolean
  rows: ProjectEditRow[]
  count: number
  target: string
  targetChosen: boolean
  targetPath: string
  changes: ProjectStructureChange[]
}

export function projectEditIdle(): ProjectEditView {
  return { phase: 'idle', refactoring: false, rows: [], count: 0, target: '', targetChosen: false, targetPath: '', changes: [] }
}

// 编辑会话持有冻结的文件版本和节点身份，提交仍由 Core 规划。
export class ProjectEditSession {
  readonly draft: ProjectStructureDraft
  readonly refactoring: boolean
  phase: ProjectEditPhase
  selected: string[] = []
  target: string | null = null
  targetChosen = false
  placement: ProjectPlacement = 'first'
  private staged = false

  constructor(snapshot: ProjectStructureSnapshot, refactoring: boolean, row: string, direct: boolean) {
    this.refactoring = refactoring
    this.draft = new ProjectStructureDraft(snapshot)
    const node = this.node(row)
    if (node) this.selected = [node.id]
    this.phase = direct ? 'target' : 'select'
  }

  node(row: string): ProjectStructureNode | undefined { return this.draft.nodes.find(item => item.row === row) }

  selectRow(row: string): void {
    const node = this.node(row)
    if (!node || this.draft.ancestors(node.id).some(id => this.selected.includes(id))) return
    this.selected = this.selected.includes(node.id) ? this.selected.filter(id => id !== node.id) :
      this.selected.filter(id => !this.draft.covered(id, [node.id])).concat(node.id)
  }

  startPlacement(row: string = ''): void {
    const node = this.node(row)
    if (node) this.selected = [node.id]
    this.target = null
    this.targetChosen = false
    this.placement = 'first'
    this.phase = 'target'
  }

  chooseTarget(row: string): boolean {
    const node = this.node(row)
    if (row && !node) return false
    if (node && this.draft.covered(node.id, this.selected)) return false
    this.target = node?.id ?? null
    this.targetChosen = true
    this.placement = node ? 'child' : 'first'
    return true
  }

  stagePlacement(placement: ProjectPlacement): boolean {
    if (!this.targetChosen) return false
    const destination = this.draft.destination(this.target, placement, this.selected)
    if (!destination || !this.draft.move(this.selected, destination)) return false
    this.placement = placement
    if (this.refactoring) {
      this.selected = []
      this.target = null
      this.targetChosen = false
      this.phase = 'select'
    } else {
      this.staged = true
      this.phase = 'review'
    }
    return true
  }

  backToSelection(): void {
    if (this.staged) {
      this.draft.undo()
      this.staged = false
      this.phase = 'target'
    } else {
      this.phase = 'select'
      this.target = null
      this.targetChosen = false
    }
  }

  reorder(row: string, sibling: string): void {
    const source = this.node(row)
    const target = this.node(sibling)
    if (!source || !target || source.parent !== target.parent) return
    const index = projectSiblings(this.draft.nodes, source.parent).findIndex(item => item.id === target.id)
    const destination = projectOrderMove(this.draft.nodes, source.id, index)
    if (destination) this.draft.move([source.id], destination)
  }

  view(): ProjectEditView {
    const nodes = this.draft.nodes
    const selections = new Map<string, number>()
    this.selected.forEach((id, index) => selections.set(id, index))
    const covered = new Set<string>()
    const changes = this.draft.changes()
    const rows = this.draft.rows(nodes.map(node => node.id), '').map((item): ProjectEditRow => {
      const node = item.node
      const selected = selections.get(node.id) ?? -1
      if (selected >= 0 || (node.parent !== null && covered.has(node.parent))) covered.add(node.id)
      return { row: node.row, title: node.title, level: item.depth + 1, selected, covered: covered.has(node.id), children: item.hasChildren }
    })
    const target = this.target === null ? undefined : nodes.find(node => node.id === this.target)
    return { phase: this.phase, refactoring: this.refactoring, rows, count: this.selected.length,
      target: target?.row ?? '', targetChosen: this.targetChosen, targetPath: this.draft.path(this.target), changes }
  }
}
