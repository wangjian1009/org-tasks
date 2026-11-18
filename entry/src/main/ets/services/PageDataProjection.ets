import { samePageTask } from './PageDataEquality'
import { checklistMovePreview } from '../ui/TaskChecklistReorder'
import { util } from '@kit.ArkTS'
import { TaskModification, TaskPlanningEdit, TaskEditContent, TaskStateCategory, PeriodCategory, TaskCreation, TaskChecklistChange, TaskChecklistItem, ContentBlock, ContentBlockChange, TaskPropertyChange } from 'liborg_tasks_harmony.so'
import { CoreTask, CoreOrgFileMetadata } from './NativeCoreService'
import { PageTaskRecord, PageTaskSnapshot, PageStateAnswer, PagePriorityAnswer, PageTaskFields, taskRecord } from './PageDataSnapshot'

function draftHtml(value: string): string {
  return `<p>${value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')}</p>`
}

function content(value: TaskEditContent, notes: string | undefined = undefined, tags: string[] | undefined = undefined,
  scheduled: TaskPlanningEdit | null | undefined = undefined, deadline: TaskPlanningEdit | null | undefined = undefined): TaskEditContent {
  return { noteRequiredStates: value.noteRequiredStates ?? [], ownTags: tags ?? value.ownTags, notes: notes ?? value.notes, notesHtml: notes === undefined ? value.notesHtml : draftHtml(notes),
    checklist: value.checklist, blocks: notes === undefined ? value.blocks :
      (notes.trim().length ? [{ id: value.blocks.find(block => block.kind !== 'checklist')?.id ?? '$local-notes',
        kind: 'text', paragraph: true, blankLinesBefore: 0, source: notes, html: draftHtml(notes), items: [] } as ContentBlock] : [])
        .concat(value.blocks.filter(block => block.kind === 'checklist')), scheduledRepeat: value.scheduledRepeat, deadlineRepeat: value.deadlineRepeat,
    scheduledPlanning: scheduled === undefined ? value.scheduledPlanning : scheduled === null ? null : {
      date: scheduled.date, time: scheduled.time === undefined ? value.scheduledPlanning?.time ?? null : scheduled.time },
    deadlinePlanning: deadline === undefined ? value.deadlinePlanning : deadline === null ? null : {
      date: deadline.date, time: deadline.time === undefined ? value.deadlinePlanning?.time ?? null : deadline.time } }
}

// 只反映用户明确选择的显示值；不解析 Org、不生成日志或重复日期，也不重新解释查询成员资格。
function modify(record: PageTaskRecord, change: TaskModification): boolean {
  const value = record.value
  if (change.field === 'TITLE' && typeof change.value === 'string') {
    value.heading = change.value
    value.headingParts = [{ text: change.value, href: null, isLink: false, count: null, link: null }]
  } else if ((change.field === 'BODY' || change.field === 'NOTES') && (typeof change.value === 'string' || change.value === null)) {
    const notes = (change.value ?? '') as string
    if (change.field === 'BODY') value.body = notes
    value.bodyHtml = draftHtml(notes); value.bodyFirstLine = notes.split('\n').find(line => line.trim().length > 0)?.trim() ?? null
    value.hasText = notes.trim().length > 0
    value.editContent = content(value.editContent, notes)
  } else if (change.field === 'PROPERTY') {
    const property = change.value as TaskPropertyChange
    const properties: Record<string, string> = {}
    const name = property.name.replace(/[a-z]/g, (letter: string): string => letter.toUpperCase())
    if (value.properties) {
      for (const key of Object.keys(value.properties)) if (key !== name) properties[key] = value.properties[key]
    }
    if (property.value !== null) properties[name] = property.value
    value.properties = properties
  } else if (change.field === 'TODO' && (typeof change.value === 'string' || change.value === null)) {
    const selected = record.states.find(answer => answer.value?.name === change.value)?.value ?? null
    if (change.value !== null && !selected) return false
    value.state = selected
    // 这是 checkbox 的待确认选择；重复、联动、CLOSED 等领域结果仍由正式提交后的事件决定。
    record.done = selected?.category === 'Done' || selected?.category === 'Cancel'
  } else if (change.field === 'CONTENT_BLOCK') {
    const block = change.value as ContentBlockChange
    if (block.type !== 'replace') return false
    const old = value.editContent
    const blocks = old.blocks.filter(item => item.id !== block.id || block.source.trim().length > 0).map((item: ContentBlock): ContentBlock =>
      item.id === block.id ? { id: item.id, kind: item.kind, paragraph: item.paragraph, blankLinesBefore: item.blankLinesBefore,
        source: block.source, html: draftHtml(block.source), items: item.items } : item)
    value.editContent = { noteRequiredStates: old.noteRequiredStates ?? [], ownTags: old.ownTags, notes: old.notes, notesHtml: old.notesHtml, checklist: old.checklist, blocks,
      scheduledRepeat: old.scheduledRepeat, deadlineRepeat: old.deadlineRepeat, scheduledPlanning: old.scheduledPlanning, deadlinePlanning: old.deadlinePlanning }
  } else if (change.field === 'CHECKLIST') {
    const checklist = change.value as TaskChecklistChange
    if (checklist.type !== 'setChecked' && checklist.type !== 'edit' && checklist.type !== 'move') return false
    const update = (item: TaskChecklistItem): TaskChecklistItem => {
      if (item.id !== checklist.id) return item
      return { id: item.id, siblingGroup: item.siblingGroup, depth: item.depth,
        text: checklist.type === 'edit' ? checklist.text : item.text,
        checked: checklist.type === 'setChecked' ? checklist.checked : item.checked,
        partial: checklist.type === 'setChecked' ? false : item.partial }
    }
    const old = value.editContent
    value.editContent = { noteRequiredStates: old.noteRequiredStates ?? [], ownTags: old.ownTags, notes: old.notes, notesHtml: old.notesHtml,
      checklist: checklist.type === 'move' ? checklistMovePreview(old.checklist, checklist.id, checklist.beforeId) : old.checklist.map(update), blocks: old.blocks.map((block: ContentBlock): ContentBlock => ({
        id: block.id, kind: block.kind, paragraph: block.paragraph, blankLinesBefore: block.blankLinesBefore,
        source: block.source, html: block.html, items: checklist.type === 'move' ? checklistMovePreview(block.items, checklist.id, checklist.beforeId) : block.items.map(update) })),
      scheduledRepeat: old.scheduledRepeat, deadlineRepeat: old.deadlineRepeat,
      scheduledPlanning: old.scheduledPlanning, deadlinePlanning: old.deadlinePlanning }
  } else if (change.field === 'PRIORITY' && (typeof change.value === 'string' || change.value === null)) {
    value.priority = change.value === null ? null : value.priorityOptions.find(option => option.name === change.value) ?? value.priority
  } else if (change.field === 'TAGS' && (Array.isArray(change.value) || change.value === null)) {
    const hidden = new Set(value.ownTags.filter(tag => !value.tags.includes(tag)))
    value.ownTags = (change.value ?? []) as string[]
    value.tags = Array.from(new Set(value.ownTags.concat(value.inheritedTags))).filter(tag => !hidden.has(tag))
    value.editContent = content(value.editContent, undefined, value.ownTags)
  } else if ((change.field === 'SCHEDULE' || change.field === 'DEADLINE') && typeof change.value !== 'string') {
    const planning = change.value as TaskPlanningEdit | null
    if (planning && typeof planning.date !== 'string') return false
    if (change.field === 'SCHEDULE') { value.scheduled = planning?.date ?? ''; value.editContent = content(value.editContent, undefined, undefined, planning) }
    else { value.deadline = planning?.date ?? ''; value.editContent = content(value.editContent, undefined, undefined, undefined, planning) }
  } else return false
  return true
}


export function projectTaskFields(task: CoreTask, changes: TaskModification[]): CoreTask {
  const record = taskRecord(task)
  let applied = false
  for (const change of changes) if (modify(record, change)) applied = true
  if (!applied) return task
  const projected = new PageTaskSnapshot(record)
  return samePageTask(task, projected) ? task : projected
}
export function createPageTask(metadata: CoreOrgFileMetadata, version: string, creation: TaskCreation): CoreTask {
  const categories: TaskStateCategory[] = ['Todo', 'Doing', 'Wait', 'Done', 'Cancel']
  const answers = categories.map((category: TaskStateCategory): PageStateAnswer => ({ category, value: metadata.taskStateOf(category) }))
  const levels: PeriodCategory[] = ['Hight', 'Middle', 'Low']
  const priorityAnswers = levels.map((category: PeriodCategory): PagePriorityAnswer => ({ category, value: metadata.taskPriorityOf(category) }))
  const tags = creation.tags ?? []
  const state = creation.state ? answers.find(answer => answer.value?.name === creation.state)?.value ?? null : null
  const value: PageTaskFields = {
    id: `$pending:${util.generateRandomUUID()}`, fullPath: { repoId: metadata.repoId, file: metadata.path, titles: creation.position.parent.titles.concat([creation.title]), occurrence: 1 },
    taskId: null, fileVersion: version, repoId: metadata.repoId, heading: creation.title, category: metadata.category,
    projectName: metadata.project(), headingParts: [{ text: creation.title, href: null, isLink: false, count: null, link: null }],
    state, createdAt: null, closedAt: null, modifiedAt: null, deletedAt: null, priority: metadata.priorityOptions.find(option => option.name === creation.priority) ?? null,
    priorityOptions: metadata.priorityOptions, defaultPriority: metadata.defaultPriority, scheduled: '', deadline: '', tags, ownTags: tags, inheritedTags: [],
    supportTags: { tags: metadata.tagOptions, groups: metadata.tagGroups },
    editContent: { noteRequiredStates: [], ownTags: tags, notes: creation.body ?? '', notesHtml: draftHtml(creation.body ?? ''), checklist: [], blocks: [],
      scheduledRepeat: null, deadlineRepeat: null, scheduledPlanning: null, deadlinePlanning: null },
    filePath: metadata.path, fileName: metadata.path.split('/').pop() ?? metadata.path, level: creation.position.parent.titles.length + 1,
    body: creation.body ?? '', bodyFirstLine: creation.body?.split('\n')[0] ?? null, addressLinks: [], bodyHtml: draftHtml(creation.body ?? ''), logbookHtml: '', logs: [],
    progress: -1, hasList: false, hasText: !!creation.body, isRepeating: false, isHabit: false, properties: {}, hasAttach: false
  }
  return new PageTaskSnapshot({ value, done: state?.category === 'Done' || state?.category === 'Cancel', states: answers, priorities: priorityAnswers })
}
