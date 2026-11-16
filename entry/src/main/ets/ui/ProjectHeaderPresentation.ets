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

export function projectTagExpression(tags: string[], groups: string[][]): string {
  const selectedGroups = groups.map((group: string[]) => group.filter((tag: string) => tags.includes(tag)))
    .filter((group: string[]) => group.length > 0)
  const others = tags.filter((tag: string) => !groups.some((group: string[]) => group.includes(tag)))
  if (others.length > 0) selectedGroups.push(others)
  return selectedGroups.map((group: string[]) => {
    const expression = group.map((tag: string) => `t.${JSON.stringify(tag)}`).join(' or ')
    return group.length > 1 ? `(${expression})` : expression
  }).join(' and ')
}

export function projectHeaderTitle(region: string, project: string): string {
  return region ? `${region} . ${project || '未命名项目'}` : project || '未命名项目'
}
