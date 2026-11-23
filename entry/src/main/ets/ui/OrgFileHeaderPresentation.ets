export interface ProjectHeaderTagSegment {
  tags: string[]
  grouped: boolean
}

// 这里只组装 Core 已解析的配置，不读取或解释 Org 原文。
export function projectHeaderRows(rows: string[][], options: string[], groups: string[][]): ProjectHeaderTagSegment[][] {
  return rows.map((row: string[]): ProjectHeaderTagSegment[] => {
    const segments: ProjectHeaderTagSegment[] = []
    let previousGroup: number = -1
    row.filter((tag: string) => options.includes(tag)).forEach((tag: string): void => {
      const group = groups.findIndex((values: string[]) => values.includes(tag))
      if (group >= 0 && previousGroup === group) segments[segments.length - 1].tags.push(tag)
      else segments.push({ tags: [tag], grouped: group >= 0 })
      previousGroup = group
    })
    return segments
  }).filter((row: ProjectHeaderTagSegment[]) => row.length > 0)
}

export function projectTagExpression(tags: string[], _groups: string[][]): string {
  // 项目页的多个点击标签表示并集；互斥组只负责候选选择时的单选行为。
  return Array.from(new Set<string>(tags))
    .map((tag: string) => `t.${JSON.stringify(tag)}`)
    .join(' or ')
}

export function projectHeaderTitle(region: string, project: string): string {
  return region ? `${region} . ${project || '未命名项目'}` : project || '未命名项目'
}
