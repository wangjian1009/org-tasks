import { CoreOrgFile, CoreTask, CoreDocumentSection } from '../services/NativeCoreService'

export interface ProjectReadingSection {
  key: string
  node: CoreTask | null
  html: string
}

// 只组装 Core 提供的同版本节点与直属正文，不解释 Org 或筛选任务。
export function projectReadingSections(file: CoreOrgFile): ProjectReadingSection[] {
  const nodes: Map<string, CoreTask> = new Map()
  file.nodes().forEach((node: CoreTask) => { nodes.set(JSON.stringify(node.fullPath), node) })
  return file.documentSections().map((section: CoreDocumentSection): ProjectReadingSection => {
    const key = section.path ? JSON.stringify(section.path) : 'preamble'
    const node = section.path ? nodes.get(key) : null
    if (section.path && !node) throw new Error('文档节点与正文版本不一致，请刷新项目。')
    return { key, node: node ?? null, html: section.html }
  })
}

export function visibleProjectTags(tags: string[], specialTags: string[]): string[] {
  return tags.filter((tag: string) => !specialTags.includes(tag))
}

// 目录只列普通章节；任务及其直属正文仍保留在完整文档中。
export function projectOutlineSections(sections: ProjectReadingSection[]): ProjectReadingSection[] {
  return sections.filter((section: ProjectReadingSection) => section.node !== null && !section.node.state)
}
