import { CoreContentBlock } from '../services/NativeCoreService'
import { samePageValue } from '../services/PageDataEquality'

// 界面身份独立于 Core 的字节位置；版本和定位更新不销毁未变化的阅读控件。
export interface TaskContentSlot { key: string; block: CoreContentBlock }
let contentSequence: number = 0

export function contentDragScrollSpeed(pointer: number, top: number, bottom: number): number {
  if (pointer < top || pointer > bottom || bottom <= top) return 0
  const edge = Math.min(96, (bottom - top) / 2)
  const fromTop = pointer - top
  const fromBottom = bottom - pointer
  const proximity = Math.max(0, 1 - Math.min(fromTop, fromBottom) / edge)
  const speed = 560 * proximity * (0.3 + 0.7 * proximity)
  return fromTop < fromBottom ? -speed : speed
}

export function reconcileTaskContent(previous: TaskContentSlot[], blocks: CoreContentBlock[]): TaskContentSlot[] {
  const available = new Map<string, TaskContentSlot[]>()
  for (const slot of previous) {
    const signature = JSON.stringify([slot.block.kind, slot.block.source])
    const entries = available.get(signature) ?? []
    entries.push(slot); available.set(signature, entries)
  }
  const positions = new Map(previous.map((slot: TaskContentSlot): [string, TaskContentSlot] => [slot.block.id, slot]))
  const matched = blocks.map((block: CoreContentBlock): TaskContentSlot | undefined => {
    const slot = positions.get(block.id)
    return slot?.block.kind === block.kind && slot.block.source === block.source ? slot : undefined
  })
  const used = new Set(matched.filter((slot: TaskContentSlot | undefined): boolean => slot !== undefined)
    .map((slot: TaskContentSlot | undefined): string => slot!.key))
  blocks.forEach((block: CoreContentBlock, index: number): void => {
    if (matched[index]) return
    const slot = available.get(JSON.stringify([block.kind, block.source]))?.find(entry => !used.has(entry.key))
    if (slot) { matched[index] = slot; used.add(slot.key) }
  })
  const next = blocks.map((block: CoreContentBlock, index: number): TaskContentSlot => {
    let slot = matched[index]
    // 同位置、同类型的内容修改复用该控件；不能占用已经匹配到其他位置的节点。
    if (!slot && previous[index]?.block.kind === block.kind && !used.has(previous[index].key)) slot = previous[index]
    if (!slot) return { key: `content:${++contentSequence}`, block }
    used.add(slot.key)
    return samePageValue(slot.block, block) ? slot : { key: slot.key, block }
  })
  return next.length === previous.length && next.every((slot: TaskContentSlot, index: number): boolean => slot === previous[index])
    ? previous : next
}
