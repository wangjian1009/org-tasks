import { CoreSettings, TaskState, TaskPriority, TaskLog } from 'liborg_tasks_harmony.so'
// Org 任务数据模型

export interface OrgTask {
  id: string           // Core 根据仓库路径、文件路径和任务标题链生成的 MD5
  heading: string      // 任务标题
  state: TaskState | null // 文件有效状态及其分类
  priority: TaskPriority | null // Core 提供的字母及分类
  scheduled: string    // ISO 日期字符串 或空
  deadline: string     // ISO 日期字符串 或空
  tags: string[]       // 标签列表
  filePath: string     // 所属文件路径
  fileName: string     // 所属文件名
  level: number        // core 投影的标题层级，从 1 开始
  body: string         // 正文内容
  bodyHtml: string      // Core 渲染的正文，不包含 LOGBOOK
  logbookHtml: string   // Core 提取并渲染的 LOGBOOK
  logs: TaskLog[]       // Core 按 Org 日志语义生成的只读条目
  progress: number     // 预留投影字段；当前 bridge 固定返回 -1
}

// 同步状态
export interface SyncResult {
  total: number        // 解析到的任务总数
  synced: number       // 已在日历中确认的任务数量
  created: number      // 新增事件数量
  updated: number      // 更新事件数量
  deleted: number      // 删除事件数量
  unchanged: number    // 未发生变化的事件数量
  skipped: number      // 没有日期而未同步的任务数量
  errors: string[]     // 错误信息
  timestamp: number    // 同步时间戳
}

export interface RepoConfig {
  id: string
  name: string
  rootDirectory: string
  webdavEnabled: boolean
  webdavUrl: string
  webdavUsername: string
  webdavPassword: string
  excludedDirectories: string[]
}

export interface SyncOptions {
  excludedDirectories: string[]
}

// 应用配置
export interface AppConfig {
  repos: RepoConfig[]
  inboxFile: string    // 新增任务写入的文件
  inboxRepoId: string  // 收件箱文件所属存储库
  somedayFile: string  // “某天”入口对应的相对文件路径，可为空
  somedayRepoId: string
  memoFile: string     // “备忘”入口对应的相对文件路径，可为空
  memoRepoId: string
  calendarName: string // 日历名称
  syncInterval: number // 同步间隔（分钟）
  coreSettings: CoreSettings
  todoDefaults: string // 外部保存的全局默认声明，缺省值由 Rust 提供
  fileDisplayMode: 'rendered' | 'source' // 文件展示方式
}

// 默认配置
export const DEFAULT_CONFIG: AppConfig = {
  repos: [],
  inboxFile: '',
  inboxRepoId: '',
  somedayFile: '',
  somedayRepoId: '',
  memoFile: '',
  memoRepoId: '',
  calendarName: 'Org Tasks',
  syncInterval: 20,
  coreSettings: { additionStates: [] },
  todoDefaults: '', // 配置加载前的占位，实际默认值从 Rust 获取
  fileDisplayMode: 'rendered'
}
