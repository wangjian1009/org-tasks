// 仅比较两段原文以供展示；任务匹配与合并仍由 Core 完成。
export interface MergeDiffLine {
  kind: string
  text: string
  localLine: number
  remoteLine: number
}

function sourceLines(source: string): string[] {
  if (source.length === 0) return []
  const lines = source.split('\n')
  return lines.map((line: string, index: number) => index < lines.length - 1 ? line + '\n' : line)
    .filter((line: string) => line.length > 0)
}

export function mergeSourceLines(source: string): MergeDiffLine[] {
  return sourceLines(source).map((text: string, index: number) => ({
    kind: 'context', text, localLine: index + 1, remoteLine: index + 1
  } as MergeDiffLine))
}

export function mergeLineDiff(local: string, remote: string): MergeDiffLine[] {
  const before = sourceLines(local)
  const after = sourceLines(remote)
  const result: MergeDiffLine[] = []
  let prefix = 0
  while (prefix < before.length && prefix < after.length && before[prefix] === after[prefix]) {
    result.push({ kind: 'context', text: before[prefix], localLine: prefix + 1, remoteLine: prefix + 1 })
    prefix++
  }
  let suffix = 0
  while (suffix < before.length - prefix && suffix < after.length - prefix &&
    before[before.length - suffix - 1] === after[after.length - suffix - 1]) suffix++
  const oldEnd = before.length - suffix
  const newEnd = after.length - suffix
  const oldCount = oldEnd - prefix
  const newCount = newEnd - prefix
  let oldIndex = prefix
  let newIndex = prefix
  // 限制矩阵大小；超大改动按整段增删展示，始终保留每一行。
  if (oldCount > 0 && newCount > 0 && oldCount * newCount <= 160000) {
    const width = newCount + 1
    const lengths = new Int32Array((oldCount + 1) * width)
    for (let i = oldCount - 1; i >= 0; i--) {
      for (let j = newCount - 1; j >= 0; j--) {
        lengths[i * width + j] = before[prefix + i] === after[prefix + j]
          ? 1 + lengths[(i + 1) * width + j + 1]
          : Math.max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
      }
    }
    while (oldIndex < oldEnd && newIndex < newEnd) {
      if (before[oldIndex] === after[newIndex]) {
        result.push({ kind: 'context', text: before[oldIndex], localLine: ++oldIndex, remoteLine: ++newIndex })
      } else if (lengths[(oldIndex - prefix + 1) * width + newIndex - prefix] >=
        lengths[(oldIndex - prefix) * width + newIndex - prefix + 1]) {
        result.push({ kind: 'removed', text: before[oldIndex], localLine: ++oldIndex, remoteLine: 0 })
      } else {
        result.push({ kind: 'added', text: after[newIndex], localLine: 0, remoteLine: ++newIndex })
      }
    }
  }
  while (oldIndex < oldEnd) {
    result.push({ kind: 'removed', text: before[oldIndex], localLine: ++oldIndex, remoteLine: 0 })
  }
  while (newIndex < newEnd) {
    result.push({ kind: 'added', text: after[newIndex], localLine: 0, remoteLine: ++newIndex })
  }
  for (let i = 0; i < suffix; i++) {
    result.push({ kind: 'context', text: before[oldEnd + i], localLine: oldEnd + i + 1, remoteLine: newEnd + i + 1 })
  }
  return result
}

export function mergeDiffText(line: MergeDiffLine): string {
  return line.text.replace(/\n$/, '').replace(/\r$/, ' ␍').replace(/\t/g, '    ')
}
