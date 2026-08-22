// 文件服务
// 读取 org 文件目录，写入 inbox.org

import { fileIo } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { OrgParser } from './OrgParser'
import { OrgParseResult } from '../models/OrgTask'

export interface OrgFileInfo {
  relativePath: string
  localMtime: number
  taskCount: number
}

export class FileService {
  static ensureDir(dirPath: string): boolean {
    try {
      fileIo.accessSync(dirPath)
      return true
    } catch {
      try {
        fileIo.mkdirSync(dirPath, true)
        return true
      } catch (e) {
        console.error('创建目录失败:', JSON.stringify(e))
        return false
      }
    }
  }

  static writeFile(filePath: string, content: string): boolean {
    try {
      const encoder = util.TextEncoder.create()
      const encoded = encoder.encode(content)
      const file = fileIo.openSync(
        filePath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC
      )
      fileIo.writeSync(file.fd, encoded.buffer as ArrayBuffer)
      fileIo.closeSync(file)
      return true
    } catch (e) {
      console.error('写入文件失败:', JSON.stringify(e))
      return false
    }
  }

  static writeFileAtomic(filePath: string, content: string): boolean {
    const tempPath = `${filePath}.tmp`
    if (!FileService.writeFile(tempPath, content)) return false
    try {
      fileIo.renameSync(tempPath, filePath)
      return true
    } catch (e) {
      console.error('替换文件失败:', JSON.stringify(e))
      try {
        fileIo.unlinkSync(tempPath)
      } catch {}
      return false
    }
  }

  static readFileIfExists(filePath: string): string {
    try {
      fileIo.accessSync(filePath)
      return FileService.readFile(filePath)
    } catch {
      return ''
    }
  }

  static removeFile(filePath: string): boolean {
    try {
      fileIo.unlinkSync(filePath)
      return true
    } catch (e) {
      console.error('删除文件失败:', JSON.stringify(e))
      return false
    }
  }

  static listFiles(dirPath: string): string[] {
    try {
      return fileIo.listFileSync(dirPath)
    } catch {
      return []
    }
  }

  static listOrgFiles(dirPath: string): OrgFileInfo[] {
    const files: OrgFileInfo[] = []
    for (const entry of FileService.listFiles(dirPath)) {
      if (!entry.endsWith('.org') || entry.startsWith('.')) continue
      const filePath = `${dirPath}/${entry}`
      try {
        const taskCount = OrgParser.parse(FileService.readFile(filePath), filePath).length
        files.push({ relativePath: entry, localMtime: FileService.getMtime(filePath), taskCount })
      } catch (e) {
        console.error(`读取文件信息失败 ${entry}:`, JSON.stringify(e))
        files.push({ relativePath: entry, localMtime: FileService.getMtime(filePath), taskCount: 0 })
      }
    }
    return files
  }

  /**
   * 读取目录下所有 .org 文件并解析任务
   */
  static async parseAllTasks(orgDir: string): Promise<OrgParseResult> {
    const result: OrgParseResult = { tasks: [], errors: [], files: 0 }

    try {
      const entries = fileIo.listFileSync(orgDir)

      for (const entry of entries) {
        if (!entry.endsWith('.org')) {
          continue
        }
        // 跳过隐藏文件和 setup 文件
        if (entry.startsWith('.')) {
          continue
        }

        const filePath = orgDir + '/' + entry
        try {
          const content = FileService.readFile(filePath)
          const tasks = OrgParser.parse(content, filePath)
          result.tasks.push(...tasks)
          result.files++
        } catch (e) {
          console.error(`解析文件失败 ${entry}:`, JSON.stringify(e))
          result.errors.push(`${entry}: ${JSON.stringify(e)}`)
        }
      }
    } catch (e) {
      console.error('读取目录失败:', JSON.stringify(e))
      result.errors.push(`读取目录失败: ${JSON.stringify(e)}`)
    }

    return result
  }

  /**
   * 读取文件内容
   */
  static readFile(filePath: string): string {
    const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY)
    const stat = fileIo.statSync(filePath)
    const buf = new ArrayBuffer(stat.size)
    fileIo.readSync(file.fd, buf)
    fileIo.closeSync(file)

    return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf))
  }

  /**
   * 追加内容到文件末尾
   */
  static appendToFile(filePath: string, content: string): boolean {
    try {
      const encoder = util.TextEncoder.create()
      const encoded = encoder.encode(content)

      // 检查文件是否存在
      let exists = true
      try {
        fileIo.accessSync(filePath)
      } catch {
        exists = false
      }

      if (exists) {
        // 追加模式打开
        const file = fileIo.openSync(filePath, fileIo.OpenMode.APPEND)
        fileIo.writeSync(file.fd, encoded.buffer as ArrayBuffer)
        fileIo.closeSync(file)
      } else {
        // 创建新文件
        const file = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY)
        fileIo.writeSync(file.fd, encoded.buffer as ArrayBuffer)
        fileIo.closeSync(file)
      }
      return true
    } catch (e) {
      console.error('写入文件失败:', JSON.stringify(e))
      return false
    }
  }

  /**
   * 新增任务到 inbox.org
   */
  static addTaskToInbox(
    orgDir: string,
    inboxFile: string,
    heading: string,
    scheduled?: string,
    deadline?: string,
    tags?: string[],
    priority?: string
  ): boolean {
    const filePath = orgDir + '/' + inboxFile
    const content = FileService.formatNewTask(heading, scheduled, deadline, tags, priority)
    return FileService.appendToFile(filePath, content)
  }

  static formatNewTask(
    heading: string,
    scheduled?: string,
    deadline?: string,
    tags?: string[],
    priority?: string
  ): string {
    return OrgParser.formatNewTask(heading, scheduled, deadline, tags, priority)
  }

  /**
   * 获取文件的最后修改时间
   */
  static getMtime(filePath: string): number {
    try {
      const stat = fileIo.statSync(filePath)
      return stat.mtime
    } catch {
      return 0
    }
  }

  /**
   * 检查目录是否存在
   */
  static dirExists(dirPath: string): boolean {
    try {
      fileIo.accessSync(dirPath)
      return true
    } catch {
      return false
    }
  }
}
