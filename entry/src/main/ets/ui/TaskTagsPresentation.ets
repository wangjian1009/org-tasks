import { CoreSupportTags } from '../services/NativeCoreService'

// 仅组织 Core 给出的候选与互斥组；不读取文件或解释 Org 配置。
export function editableTagNames(config: CoreSupportTags | null, own: string[], inherited: string[]): string[] {
  return Array.from(new Set<string>([...(config?.tags ?? []), ...own, ...inherited]))
}

export function editableTagGroups(names: string[], config: CoreSupportTags | null): string[][] {
  const groups = (config?.groups ?? []).map((group: string[]) => group.filter((tag: string) => names.includes(tag)))
    .filter((group: string[]) => group.length > 0)
  const others = names.filter((tag: string) => !groups.some((group: string[]) => group.includes(tag)))
  return others.length > 0 ? [...groups, others] : groups
}

export function selectedTagNames(selected: string[], inherited: string[], visible: string[]): string[] {
  return Array.from(new Set<string>([...selected.filter((tag: string) => visible.includes(tag)), ...inherited]))
}

export function inheritedTagConflict(tag: string, inherited: string[], config: CoreSupportTags | null): string | undefined {
  return inherited.find((value: string) => value !== tag &&
    (config?.groups ?? []).some((group: string[]) => group.includes(tag) && group.includes(value)))
}

export function toggleEditableTag(selected: string[], tag: string, config: CoreSupportTags | null): string[] {
  if (selected.includes(tag)) return selected.filter((value: string) => value !== tag)
  return selected.filter((value: string) => !(config?.groups ?? []).some((group: string[]) =>
    group.includes(tag) && group.includes(value))).concat(tag)
}
