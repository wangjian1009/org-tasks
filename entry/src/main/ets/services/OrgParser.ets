// Org 文件解析器
// 解析 org 格式文件，提取 TODO 任务及其属性

import { OrgTask } from '../models/OrgTask'

// TODO 关键字
const TODO_KEYWORDS: string[] = ['TODO', 'NEXT', 'WAIT', 'DONE', 'CNCL']

// 日期正则：匹配 <2026-08-12 Tue> 或 [2026-08-12 Tue] 格式
const DATE_PATTERN = /[<\[](\d{4})-(\d{2})-(\d{2})(?:\s+\w+)?(?:\s+(\d{2}:\d{2}))?(?:-\d{2}:\d{2})?[>\]]/

// 进度正则：匹配 [3/5] 或 [50%] 格式
const PROGRESS_FRAC = /\[(\d+)\/(\d+)\]/
const PROGRESS_PCT = /\[(\d+)%\]/

// 优先级正则：匹配 [#A] [#B] [#C]
const PRIORITY_PATTERN = /\[#([A-Z])\]/

export class OrgParser {
  /**
   * 解析单个 org 文件内容，返回任务列表
   */
  static parse(content: string, filePath: string): OrgTask[] {
    const lines = content.split('\n')
    const tasks: OrgTask[] = []
    let currentTask: Partial<OrgTask> | null = null
    let bodyLines: string[] = []
    let inProperties = false
    let inLogbook = false

    const fileName = filePath.split('/').pop() || filePath

    const flushTask = () => {
      if (currentTask && currentTask.todoState) {
        currentTask.body = bodyLines.join('\n').trim()
        currentTask.filePath = filePath
        currentTask.fileName = fileName
        currentTask.id = OrgParser.generateId(filePath, currentTask.heading || '')
        tasks.push(currentTask as OrgTask)
      }
      currentTask = null
      bodyLines = []
    }

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i]

      // 跳过文件级属性
      if (line.startsWith('#+')) {
        continue
      }

      // 检测标题行
      const headingMatch = line.match(/^(\*+)\s+(.*)/)
      if (headingMatch) {
        // 先保存上一个任务
        flushTask()

        const level = headingMatch[1].length
        let rest = headingMatch[2]

        // 提取 TODO 状态
        let todoState = ''
        for (const kw of TODO_KEYWORDS) {
          if (rest.startsWith(kw + ' ')) {
            todoState = kw
            rest = rest.substring(kw.length + 1)
            break
          } else if (rest === kw) {
            todoState = kw
            rest = ''
            break
          }
        }

        // 提取优先级 [#A]
        let priority = ''
        const priorityMatch = rest.match(PRIORITY_PATTERN)
        if (priorityMatch) {
          priority = priorityMatch[1]
          rest = rest.replace(PRIORITY_PATTERN, '').trim()
        }

        // 提取行内标签 :tag1:tag2:
        let tags: string[] = []
        const tagMatch = rest.match(/\s+:([\w:]+):$/)
        if (tagMatch) {
          tags = tagMatch[1].split(':').filter(t => t.length > 0)
          rest = rest.replace(/\s+:[\w:]+:$/, '').trim()
        }

        // 提取进度
        let progress = -1
        const fracMatch = rest.match(PROGRESS_FRAC)
        if (fracMatch) {
          const done = parseInt(fracMatch[1])
          const total = parseInt(fracMatch[2])
          progress = total > 0 ? Math.round(done / total * 100) : -1
        } else {
          const pctMatch = rest.match(PROGRESS_PCT)
          if (pctMatch) {
            progress = parseInt(pctMatch[1])
          }
        }

        currentTask = {
          heading: rest,
          todoState: todoState,
          priority: priority,
          tags: tags,
          level: level,
          scheduled: '',
          deadline: '',
          progress: progress,
          body: ''
        }
        continue
      }

      // 在标题内部处理
      if (currentTask) {
        // PROPERTIES 块
        if (line.trim() === ':PROPERTIES:') {
          inProperties = true
          continue
        }
        if (inProperties) {
          if (line.trim() === ':END:') {
            inProperties = false
            continue
          }
          // 解析属性 :KEY: value
          const propMatch = line.match(/^\s*:(\w+):\s*(.*)/)
          if (propMatch) {
            const key = propMatch[1].toUpperCase()
            const value = propMatch[2].trim()
            // 目前不需要额外属性，ID 由 hash 生成
          }
          continue
        }

        // LOGBOOK 块
        if (line.trim() === ':LOGBOOK:') {
          inLogbook = true
          continue
        }
        if (inLogbook) {
          if (line.trim() === ':END:') {
            inLogbook = false
          }
          continue
        }

        // SCHEDULED 行
        if (line.trim().startsWith('SCHEDULED:')) {
          const dateMatch = line.match(DATE_PATTERN)
          if (dateMatch) {
            currentTask.scheduled = OrgParser.formatDate(dateMatch)
          }
          continue
        }

        // DEADLINE 行
        if (line.trim().startsWith('DEADLINE:')) {
          const dateMatch = line.match(DATE_PATTERN)
          if (dateMatch) {
            currentTask.deadline = OrgParser.formatDate(dateMatch)
          }
          continue
        }

        // 其他行归入 body
        bodyLines.push(line)
      }
    }

    // 处理最后一个任务
    flushTask()

    return tasks
  }

  /**
   * 将正则匹配结果转为 ISO 日期字符串
   */
  private static formatDate(match: RegExpMatchArray): string {
    const year = match[1]
    const month = match[2]
    const day = match[3]
    const time = match[4] || ''
    if (time) {
      return `${year}-${month}-${day}T${time}:00`
    }
    return `${year}-${month}-${day}`
  }

  /**
   * 生成任务唯一 ID
   */
  private static generateId(filePath: string, heading: string): string {
    const raw = filePath + '::' + heading
    let hash = 0
    for (let i = 0; i < raw.length; i++) {
      const char = raw.charCodeAt(i)
      hash = ((hash << 5) - hash) + char
      hash = hash & hash // 转 32 位整数
    }
    return Math.abs(hash).toString(16)
  }

  /**
   * 生成新增任务的 org 格式文本
   */
  static formatNewTask(
    heading: string,
    scheduled?: string,
    deadline?: string,
    tags?: string[],
    priority?: string
  ): string {
    let line = '* TODO '

    if (priority) {
      line += `[#${priority}] `
    }

    line += heading

    if (tags && tags.length > 0) {
      line += ' :' + tags.join(':') + ':'
    }

    let result = line + '\n'

    if (scheduled) {
      result += `SCHEDULED: <${scheduled}>\n`
    }
    if (deadline) {
      result += `DEADLINE: <${deadline}>\n`
    }

    return result
  }
}
