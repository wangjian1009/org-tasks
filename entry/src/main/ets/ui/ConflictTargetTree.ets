import { CoreConflictTarget, CoreOrgFile, CoreTaskPath } from '../services/NativeCoreService'

// 层级、路径与合法位置均来自 Core；这里只组装树形展示，不解析 Org。
export interface ConflictTargetNode {
  key: string
  label: string
  path: CoreTaskPath
  target: CoreConflictTarget | undefined
  after: CoreConflictTarget | undefined
  children: ConflictTargetNode[]
}

export interface ConflictTargetRow {
  key: string
  label: string
  depth: number
  branch: boolean
  expanded: boolean
  target: CoreConflictTarget | undefined
}

export function sameConflictPath(a: CoreTaskPath, b: CoreTaskPath): boolean {
  return a.repoId === b.repoId && a.file === b.file && (a.occurrence ?? 1) === (b.occurrence ?? 1) &&
    a.titles.length === b.titles.length && a.titles.every((title, index) => title === b.titles[index])
}

export function conflictTargetTree(file: CoreOrgFile, reason: string): ConflictTargetNode {
  const insert = !['modify', 'delete'].includes(reason)
  const positions = insert ? file.insertionPositions() : []
  const root: ConflictTargetNode = {
    key: JSON.stringify(file.fullPath), label: file.title() || file.path, path: file.fullPath,
    target: insert && positions.some(p => sameConflictPath(p.parent, file.fullPath) && !p.after) ?
      { type: 'insert', data: { parent: file.fullPath } } : undefined,
    after: undefined, children: []
  }
  const stack: ConflictTargetNode[] = [root]
  for (const task of file.nodes()) {
    while (stack.length > task.fullPath.titles.length) stack.pop()
    const first = positions.find(p => sameConflictPath(p.parent, task.fullPath) && !p.after)
    const after = positions.find(p => !!p.after && sameConflictPath(p.after, task.fullPath))
    const node: ConflictTargetNode = {
      key: JSON.stringify(task.fullPath), label: task.heading, path: task.fullPath,
      target: insert ? first ? { type: 'insert', data: first } : undefined : { type: 'existing', data: task.fullPath },
      after: after ? { type: 'insert', data: after } : undefined, children: []
    }
    stack[stack.length - 1].children.push(node)
    stack.push(node)
  }
  return root
}

export function conflictTargetRows(node: ConflictTargetNode, expanded: string[], depth: number = 0): ConflictTargetRow[] {
  const open = expanded.includes(node.key)
  const rows: ConflictTargetRow[] = [{ key: node.key, label: node.label, depth,
    branch: node.children.length > 0, expanded: open, target: node.target }]
  if (open) {
    for (const child of node.children) {
      rows.push(...conflictTargetRows(child, expanded, depth + 1))
      if (child.after) rows.push({ key: `${child.key}:after`, label: `${child.label} 之后`, depth: depth + 1,
        branch: false, expanded: false, target: child.after })
    }
  }
  return rows
}
