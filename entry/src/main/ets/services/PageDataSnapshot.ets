import { TaskPath, TitlePart, TaskState, TaskStateCategory, TaskPriority, PeriodCategory, SupportTags,
  QueryOrderPart, TaskEditContent, AddressLink, TaskLog, TaskStateCount, TaskCategory } from 'liborg_tasks_harmony.so'
import { CoreTask, CoreOrgFileMetadata, CoreQueryResult } from './NativeCoreService'

export interface PageStateAnswer { category: TaskStateCategory; value: TaskState | null }
export interface PagePriorityAnswer { category: PeriodCategory; value: TaskPriority | null }
export interface PageTaskFields {
  orderKey?: QueryOrderPart[]
  projectName: string | null
  id: string
  fullPath: TaskPath
  taskId: string | null
  fileVersion: string
  repoId: string
  heading: string
  category: string | null
  headingParts: TitlePart[]
  state: TaskState | null
  createdAt: number | null
  closedAt: number | null
  modifiedAt: number | null
  priority: TaskPriority | null
  priorityOptions: TaskPriority[]
  defaultPriority: TaskPriority
  scheduled: string
  deadline: string
  tags: string[]
  ownTags: string[]
  inheritedTags: string[]
  supportTags: SupportTags | null
  editContent: TaskEditContent
  filePath: string
  fileName: string
  level: number
  body: string
  bodyFirstLine: string | null
  addressLinks: AddressLink[]
  bodyHtml: string
  logbookHtml: string
  logs: TaskLog[]
  progress: number
  hasList: boolean
  hasText: boolean
  isRepeating: boolean
  isHabit: boolean
  hasAttach: boolean
}
export interface PageTaskRecord { value: PageTaskFields; done: boolean; states: PageStateAnswer[]; priorities: PagePriorityAnswer[] }
interface MetadataFields {
  orderKey?: QueryOrderPart[]
  priorityOptions: TaskPriority[]
  defaultPriority: TaskPriority
  projectName: string | null
  category: string | null
  repoId: string
  path: string
  title: string | null
  titleParts: TitlePart[]
  tagOptions: string[]
  tagGroups: string[][]
  isIgnore: boolean
  hasConflict: boolean
  taskStateCounts: TaskStateCount[]
  byteLength: number
  modifiedAt: number | null
}
export interface MetadataRecord { value: MetadataFields; states: PageStateAnswer[]; priorities: PagePriorityAnswer[] }
function states(value: CoreTask | CoreOrgFileMetadata): PageStateAnswer[] {
  const categories: TaskStateCategory[] = ['Todo', 'Doing', 'Wait', 'Done', 'Cancel']
  return categories.map((category: TaskStateCategory): PageStateAnswer => ({ category, value: value.taskStateOf(category) }))
}
function priorities(value: CoreTask | CoreOrgFileMetadata): PagePriorityAnswer[] {
  const categories: PeriodCategory[] = ['Hight', 'Middle', 'Low']
  return categories.map((category: PeriodCategory): PagePriorityAnswer => ({ category, value: value.taskPriorityOf(category) }))
}
function stateAnswer(answers: PageStateAnswer[], category: TaskStateCategory): TaskState | null {
  const answer = answers.find(item => item.category === category)
  if (!answer) throw new Error('状态分类无效')
  return answer.value ? { name: answer.value.name, category: answer.value.category } : null
}
function priorityAnswer(answers: PagePriorityAnswer[], category: PeriodCategory): TaskPriority | null {
  const answer = answers.find(item => item.category === category)
  if (!answer) throw new Error('优先级分类无效')
  return answer.value ? { name: answer.value.name, category: answer.value.category } : null
}

// 序列化的是只读显示字段及 Core 已给出的答案；恢复时使用界面模型自己的方法，不调用丢失绑定的 N-API 方法。
export function taskRecord(value: CoreTask): PageTaskRecord {
  return { value: {
    orderKey: value.orderKey,
    projectName: value.projectName,
    id: value.id,
    fullPath: value.fullPath,
    taskId: value.taskId,
    fileVersion: value.fileVersion,
    repoId: value.repoId,
    heading: value.heading,
    category: value.category,
    headingParts: value.headingParts,
    state: value.state,
    createdAt: value.createdAt,
    closedAt: value.closedAt,
    modifiedAt: value.modifiedAt,
    priority: value.priority,
    priorityOptions: value.priorityOptions,
    defaultPriority: value.defaultPriority,
    scheduled: value.scheduled,
    deadline: value.deadline,
    tags: value.tags,
    ownTags: value.ownTags,
    inheritedTags: value.inheritedTags,
    supportTags: value.supportTags,
    editContent: value.editContent,
    filePath: value.filePath,
    fileName: value.fileName,
    level: value.level,
    body: value.body,
    bodyFirstLine: value.bodyFirstLine,
    addressLinks: value.addressLinks,
    bodyHtml: value.bodyHtml,
    logbookHtml: value.logbookHtml,
    logs: value.logs,
    progress: value.progress,
    hasList: value.hasList,
    hasText: value.hasText,
    isRepeating: value.isRepeating,
    isHabit: value.isHabit,
    hasAttach: value.hasAttach,
  }, done: value.isDone(), states: states(value), priorities: priorities(value) }
}

export class PageTaskSnapshot {
  readonly orderKey?: QueryOrderPart[]
  readonly projectName: string | null
  readonly id: string
  readonly fullPath: TaskPath
  readonly taskId: string | null
  readonly fileVersion: string
  readonly repoId: string
  readonly heading: string
  readonly category: string | null
  readonly headingParts: TitlePart[]
  readonly state: TaskState | null
  readonly createdAt: number | null
  readonly closedAt: number | null
  readonly modifiedAt: number | null
  readonly priority: TaskPriority | null
  readonly priorityOptions: TaskPriority[]
  readonly defaultPriority: TaskPriority
  readonly scheduled: string
  readonly deadline: string
  readonly tags: string[]
  readonly ownTags: string[]
  readonly inheritedTags: string[]
  readonly supportTags: SupportTags | null
  readonly editContent: TaskEditContent
  readonly filePath: string
  readonly fileName: string
  readonly level: number
  readonly body: string
  readonly bodyFirstLine: string | null
  readonly addressLinks: AddressLink[]
  readonly bodyHtml: string
  readonly logbookHtml: string
  readonly logs: TaskLog[]
  readonly progress: number
  readonly hasList: boolean
  readonly hasText: boolean
  readonly isRepeating: boolean
  readonly isHabit: boolean
  readonly hasAttach: boolean
  isDone: () => boolean
  project: () => string | null
  taskStateOf: (category: TaskStateCategory) => TaskState | null
  taskPriorityOf: (category: PeriodCategory) => TaskPriority | null
  constructor(record: PageTaskRecord) {
    this.orderKey = record.value.orderKey
    this.projectName = record.value.projectName
    this.id = record.value.id
    this.fullPath = record.value.fullPath
    this.taskId = record.value.taskId
    this.fileVersion = record.value.fileVersion
    this.repoId = record.value.repoId
    this.heading = record.value.heading
    this.category = record.value.category
    this.headingParts = record.value.headingParts
    this.state = record.value.state
    this.createdAt = record.value.createdAt
    this.closedAt = record.value.closedAt
    this.modifiedAt = record.value.modifiedAt
    this.priority = record.value.priority
    this.priorityOptions = record.value.priorityOptions
    this.defaultPriority = record.value.defaultPriority
    this.scheduled = record.value.scheduled
    this.deadline = record.value.deadline
    this.tags = record.value.tags
    this.ownTags = record.value.ownTags
    this.inheritedTags = record.value.inheritedTags
    this.supportTags = record.value.supportTags
    this.editContent = record.value.editContent
    this.filePath = record.value.filePath
    this.fileName = record.value.fileName
    this.level = record.value.level
    this.body = record.value.body
    this.bodyFirstLine = record.value.bodyFirstLine
    this.addressLinks = record.value.addressLinks
    this.bodyHtml = record.value.bodyHtml
    this.logbookHtml = record.value.logbookHtml
    this.logs = record.value.logs
    this.progress = record.value.progress
    this.hasList = record.value.hasList
    this.hasText = record.value.hasText
    this.isRepeating = record.value.isRepeating
    this.isHabit = record.value.isHabit
    this.hasAttach = record.value.hasAttach
    this.isDone = (): boolean => record.done
    this.project = (): string | null => record.value.projectName
    this.taskStateOf = (category: TaskStateCategory): TaskState | null => stateAnswer(record.states, category)
    this.taskPriorityOf = (category: PeriodCategory): TaskPriority | null => priorityAnswer(record.priorities, category)
  }
}

export function metadataRecord(value: CoreOrgFileMetadata): MetadataRecord {
  return { value: {
    orderKey: value.orderKey,
    priorityOptions: value.priorityOptions,
    defaultPriority: value.defaultPriority,
    projectName: value.projectName,
    category: value.category,
    repoId: value.repoId,
    path: value.path,
    title: value.title,
    titleParts: value.titleParts,
    tagOptions: value.tagOptions,
    tagGroups: value.tagGroups,
    isIgnore: value.isIgnore,
    hasConflict: value.hasConflict,
    taskStateCounts: value.taskStateCounts,
    byteLength: value.byteLength,
    modifiedAt: value.modifiedAt,
  }, states: states(value), priorities: priorities(value) }
}
export class PageMetadataSnapshot implements CoreOrgFileMetadata {
  readonly orderKey?: QueryOrderPart[]
  readonly priorityOptions: TaskPriority[]
  readonly defaultPriority: TaskPriority
  readonly projectName: string | null
  readonly category: string | null
  readonly repoId: string
  readonly path: string
  readonly title: string | null
  readonly titleParts: TitlePart[]
  readonly tagOptions: string[]
  readonly tagGroups: string[][]
  readonly isIgnore: boolean
  readonly hasConflict: boolean
  readonly taskStateCounts: TaskStateCount[]
  readonly byteLength: number
  readonly modifiedAt: number | null
  project: () => string | null
  taskStateOf: (category: TaskStateCategory) => TaskState | null
  taskPriorityOf: (category: PeriodCategory) => TaskPriority | null
  constructor(record: MetadataRecord) {
    this.orderKey = record.value.orderKey
    this.priorityOptions = record.value.priorityOptions
    this.defaultPriority = record.value.defaultPriority
    this.projectName = record.value.projectName
    this.category = record.value.category
    this.repoId = record.value.repoId
    this.path = record.value.path
    this.title = record.value.title
    this.titleParts = record.value.titleParts
    this.tagOptions = record.value.tagOptions
    this.tagGroups = record.value.tagGroups
    this.isIgnore = record.value.isIgnore
    this.hasConflict = record.value.hasConflict
    this.taskStateCounts = record.value.taskStateCounts
    this.byteLength = record.value.byteLength
    this.modifiedAt = record.value.modifiedAt
    this.project = (): string | null => record.value.projectName
    this.taskStateOf = (category: TaskStateCategory): TaskState | null => stateAnswer(record.states, category)
    this.taskPriorityOf = (category: PeriodCategory): TaskPriority | null => priorityAnswer(record.priorities, category)
  }
}

export function samePagePath(left: TaskPath, right: TaskPath): boolean {
  return left.repoId === right.repoId && left.file === right.file && (left.occurrence ?? 1) === (right.occurrence ?? 1) &&
    JSON.stringify(left.titles) === JSON.stringify(right.titles)
}


export interface CachedDataSet {
  version: number
  name: string
  type: 'task' | 'file'
  tasks: PageTaskRecord[]
  categories: TaskCategory[]
  files: MetadataRecord[]
}
export function cacheDataSet(name: string, data: CoreQueryResult): CachedDataSet {
  if (data.type === 'notification') throw new Error('页面数据集不缓存通知查询')
  return { version: 0, name, type: data.type, tasks: data.type === 'task' ? data.result.tasks.map(taskRecord) : [],
    categories: data.type === 'task' ? data.result.categories : [], files: data.type === 'file' ? data.result.map(metadataRecord) : [] }
}
export function restoreDataSet(data: CachedDataSet): CoreQueryResult {
  if (data.type === 'task') {
    if (!Array.isArray(data.tasks) || !Array.isArray(data.categories) || data.tasks.some(item =>
      !item.value || typeof item.value.id !== 'string' || typeof item.value.fileVersion !== 'string' ||
      typeof item.value.heading !== 'string' || !item.value.fullPath || !item.value.editContent ||
      !Array.isArray(item.states) || item.states.length !== 5 || !Array.isArray(item.priorities) || item.priorities.length !== 3)) throw new Error('页面任务缓存无效')
    return { type: 'task', result: { tasks: data.tasks.map(item => new PageTaskSnapshot(item)), categories: data.categories } }
  }
  if (data.type === 'file') {
    if (!Array.isArray(data.files) || data.files.some(item => !item.value || typeof item.value.repoId !== 'string' ||
      typeof item.value.path !== 'string' || !Array.isArray(item.states) || item.states.length !== 5 ||
      !Array.isArray(item.priorities) || item.priorities.length !== 3)) throw new Error('页面文件缓存无效')
    return { type: 'file', result: data.files.map(item => new PageMetadataSnapshot(item)) }
  }
  throw new Error('页面缓存数据集类型无效')
}
export function copyDataSet(data: CoreQueryResult): CoreQueryResult { return restoreDataSet(cacheDataSet('', data)) }
