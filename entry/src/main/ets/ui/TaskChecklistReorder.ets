import { CoreTaskChecklistItem } from '../services/NativeCoreService'

// 只重排 Core 投影以展示拖动预览；同级身份由 Core 提供，源字节与合法性仍由 Core 校验。
export function checklistBlockEnd(items: CoreTaskChecklistItem[], index: number): number {
  let end = index + 1
  while (end < items.length && items[end].depth > items[index].depth) end++
  return end
}

export function checklistSiblings(items: CoreTaskChecklistItem[], id: string): CoreTaskChecklistItem[] {
  const item = items.find(current => current.id === id)
  return item ? items.filter(current => current.siblingGroup === item.siblingGroup) : []
}

export function checklistMovePreview(items: CoreTaskChecklistItem[], id: string, beforeId: string | null): CoreTaskChecklistItem[] {
  const start = items.findIndex(item => item.id === id)
  if (start < 0 || beforeId === id) return items.slice()
  const siblings = checklistSiblings(items, id)
  if (beforeId !== null && !siblings.some(item => item.id === beforeId)) return items.slice()
  const end = checklistBlockEnd(items, start)
  const block = items.slice(start, end)
  const rest = items.slice(0, start).concat(items.slice(end))
  let at = beforeId === null ? -1 : rest.findIndex(item => item.id === beforeId)
  if (beforeId === null) {
    const last = rest.findIndex(item => item.id === siblings.filter(item => item.id !== id).pop()?.id)
    at = last < 0 ? start : checklistBlockEnd(rest, last)
  }
  return rest.slice(0, at).concat(block, rest.slice(at))
}

export class TaskChecklistDrag {
  readonly items: CoreTaskChecklistItem[]
  readonly moving: CoreTaskChecklistItem[]
  readonly id: string
  readonly grab: number
  readonly height: number
  readonly minY: number
  readonly maxY: number
  beforeId: string | null
  valid: boolean = true
  top: number
  private heights: Map<string, number>

  constructor(items: CoreTaskChecklistItem[], id: string, heights: Map<string, number>, pointerY: number) {
    this.items = items.slice()
    this.id = id
    this.heights = new Map(heights)
    const start = items.findIndex(item => item.id === id)
    this.moving = items.slice(start, checklistBlockEnd(items, start))
    this.top = this.offset(start)
    this.grab = pointerY - this.top
    this.height = this.moving.reduce((sum, item) => sum + this.rowHeight(item), 0)
    const siblings = checklistSiblings(items, id)
    const index = siblings.findIndex(item => item.id === id)
    this.beforeId = siblings[index + 1]?.id ?? null
    this.minY = this.offset(items.findIndex(item => item.id === siblings[0].id))
    const last = items.findIndex(item => item.id === siblings[siblings.length - 1].id)
    this.maxY = this.offset(checklistBlockEnd(items, last))
  }

  private rowHeight(item: CoreTaskChecklistItem): number { return Math.max(44, this.heights.get(item.id) ?? 44) }
  private offset(index: number): number { return this.items.slice(0, index).reduce((sum, item) => sum + this.rowHeight(item), 0) }

  update(pointerY: number, inside: boolean): void {
    this.top = pointerY - this.grab
    this.valid = inside && pointerY >= this.minY && pointerY <= this.maxY
    if (!this.valid) return
    const center = this.top + this.rowHeight(this.moving[0]) / 2
    const siblings = checklistSiblings(this.items, this.id).filter(item => item.id !== this.id)
    this.beforeId = siblings.find(item => center < this.offset(this.items.findIndex(current => current.id === item.id)) + this.rowHeight(item) / 2)?.id ?? null
  }

  preview(): CoreTaskChecklistItem[] { return checklistMovePreview(this.items, this.id, this.beforeId) }
  changed(): boolean { return this.preview().some((item, index) => item.id !== this.items[index].id) }
  contains(id: string): boolean { return this.moving.some(item => item.id === id) }
  placeholderTop(): number {
    const preview = this.preview()
    return preview.slice(0, preview.findIndex(item => item.id === this.id)).reduce((sum, item) => sum + this.rowHeight(item), 0)
  }
}

export function checklistEdgeScroll(pointerY: number, top: number, bottom: number): number {
  if (bottom <= top || pointerY < top || pointerY > bottom) return 0
  if (pointerY < top + 40) return -240 * Math.min(1, (top + 40 - pointerY) / 40)
  if (pointerY > bottom - 40) return 240 * Math.min(1, (pointerY - bottom + 40) / 40)
  return 0
}
