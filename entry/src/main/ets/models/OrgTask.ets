// Org 任务数据模型

export interface OrgTask {
  id: string           // 文件路径 + heading hash
  heading: string      // 任务标题
  todoState: string    // TODO/NEXT/WAIT/DONE/CNCL
  priority: string     // A/B/C 或空
  scheduled: string    // ISO 日期字符串 或空
  deadline: string     // ISO 日期字符串 或空
  tags: string[]       // 标签列表
  filePath: string     // 所属文件路径
  fileName: string     // 所属文件名
  level: number        // 标题层级 (1-6)
  body: string         // 正文内容
  progress: number     // 进度 0-100，-1 表示无进度
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

// Org 文件读取结果。存在读取或解析错误时，调用方不得执行删除同步。
export interface OrgParseResult {
  tasks: OrgTask[]
  errors: string[]
  files: number
}

// 应用配置
export interface AppConfig {
  orgDir: string       // org 文件目录（坚果云同步路径）
  inboxFile: string    // 新增任务写入的文件
  calendarName: string // 日历名称
  syncInterval: number // 同步间隔（分钟）
  webdavEnabled: boolean
  webdavUrl: string
  webdavUsername: string
  webdavPassword: string
}

// 默认配置
export const DEFAULT_CONFIG: AppConfig = {
  orgDir: '/storage/Users/currentUser/CloudDrive/org-roam/tasks',
  inboxFile: 'inbox.org',
  calendarName: 'Org Tasks',
  syncInterval: 15,
  webdavEnabled: false,
  webdavUrl: '',
  webdavUsername: '',
  webdavPassword: ''
}
