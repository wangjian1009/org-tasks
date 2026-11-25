import { localizedText } from './LocalizedText'
import { CoreOrgFile, CoreTask, CoreDocumentSection, CoreContentBlock, CoreContentNode, CoreDocumentLinkTarget } from '../services/NativeCoreService'

export interface OrgFileReadingSection {
  key: string
  node: CoreTask | null
  html: string
  blocks: CoreContentBlock[]
  contentTree?: CoreContentNode[]
  linkTargets: CoreDocumentLinkTarget[]
}

// 只组装 Core 提供的同版本节点与直属正文，不解释 Org 或筛选任务。
export function projectReadingSections(file: CoreOrgFile, tasks: CoreTask[] = file.nodes()): OrgFileReadingSection[] {
  const nodes: Map<string, CoreTask> = new Map()
  tasks.forEach((node: CoreTask) => { nodes.set(JSON.stringify(node.fullPath), node) })
  return file.documentSections().map((section: CoreDocumentSection): OrgFileReadingSection => {
    const key = section.path ? JSON.stringify(section.path) : 'preamble'
    const node = section.path ? nodes.get(key) : null
    if (section.path && !node) throw new Error(localizedText($r('app.string.text_the_document_node_does_not_match_the')))
    return { key, node: node ?? null, html: section.html, blocks: section.blocks, contentTree: section.contentTree, linkTargets: section.linkTargets }
  })
}

export function visibleProjectTags(tags: string[], specialTags: string[]): string[] {
  return tags.filter((tag: string) => !specialTags.includes(tag))
}

// 目录只列普通章节；任务及其直属正文仍保留在完整文档中。
export function projectOutlineSections(sections: OrgFileReadingSection[]): OrgFileReadingSection[] {
  return sections.filter((section: OrgFileReadingSection) => section.node !== null && !section.node.state)
}

// 成员与源顺序变化才更新文档容器，属性和正文由各章节的任务订阅局部更新。
export function reconcileProjectSections(previous: OrgFileReadingSection[], tasks: CoreTask[], key: (task: CoreTask) => string): OrgFileReadingSection[] {
  const preamble = previous.filter(section => section.node === null)
  const old = new Map<string, OrgFileReadingSection>()
  for (const section of previous) if (section.node) old.set(section.key, section)
  const next = preamble.concat(tasks.map((task: CoreTask): OrgFileReadingSection => {
    const identity = key(task)
    return old.get(identity) ?? { key: identity, node: task, html: '', blocks: task.editContent.blocks, linkTargets: [] }
  }))
  return previous.length === next.length && previous.every((section, index) => section === next[index]) ? previous : next
}

export interface OrgFileReadingItem {
  section: OrgFileReadingSection
  hasChildren: boolean
  contextOnly: boolean
  visible: boolean
}

// 完整保留源节点；标签命中集合由 Core 查询提供，展示只更新可见性与祖先路径。
export function projectReadingItems(sections: OrgFileReadingSection[], matches: string[] | null = null,
  revealed: string[] = [], editLevels?: Map<string, number>, orderFolded?: string[]): OrgFileReadingItem[] {
  const result: OrgFileReadingItem[] = []
  const parents: number[] = []
  const available: boolean[] = []
  const ancestors: number[] = []
  const matched = matches === null ? null : new Set<string>(matches)
  const folded = orderFolded === undefined ? null : new Set<string>(orderFolded)
  let hiddenLevel = 0
  for (let index = 0; index < sections.length; index++) {
    const section = sections[index], node = section.node
    if (!node) {
      result.push({ section, hasChildren: false, contextOnly: false, visible: true })
      parents.push(-1); available.push(true)
      continue
    }
    const level = editLevels?.get(section.key) ?? node.level
    while (ancestors.length > 0) {
      const candidate = sections[ancestors[ancestors.length - 1]]
      if ((editLevels?.get(candidate.key) ?? candidate.node!.level) < level) break
      ancestors.pop()
    }
    parents.push(ancestors.length > 0 ? ancestors[ancestors.length - 1] : -1)
    ancestors.push(index)
    const hidden = hiddenLevel > 0 && level > hiddenLevel
    if (!hidden) {
      const collapsed = folded ? folded.has(section.key) : !revealed.includes(section.key) &&
        (node.editContent.ownTags.includes('ARCHIVE') || node.property('VISIBILITY') === 'folded')
      hiddenLevel = collapsed ? level : 0
    }
    const next = sections[index + 1]?.node
    const hasChildren = !!next && (editLevels?.get(sections[index + 1].key) ?? next.level) > level
    const contextOnly = matched !== null && !!node.state && !matched.has(node.id)
    available.push(!hidden)
    result.push({ section, hasChildren, contextOnly, visible: !hidden && !contextOnly })
  }
  // 普通章节与命中任务的所有祖先均保留；归档和主动折叠继续优先隐藏后代。
  for (let index = result.length - 1; index >= 0; index--) {
    const parent = parents[index]
    if (result[index].visible && parent >= 0 && available[parent]) result[parent].visible = true
  }
  return result
}
