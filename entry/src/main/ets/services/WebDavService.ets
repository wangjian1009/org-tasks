// WebDAV mirror and durable outbox for org files.

import { Context } from '@kit.AbilityKit'
import { http } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import { AppConfig } from '../models/OrgTask'
import { FileService, OrgFileInfo } from './FileService'

export interface WebDavResult {
  ok: boolean
  localDir: string
  downloaded: number
  message: string
}

export interface WebDavCachedFile extends OrgFileInfo {
  status: 'synced' | 'pending'
}

interface WebDavFileState {
  relativePath: string
  remoteEtag: string
  lastSyncedAt: number
}

interface WebDavState {
  files: WebDavFileState[]
}

interface RemoteFile {
  exists: boolean
  content: string
  etag: string
}

interface ResponseHeaders {
  etag?: string
  ETag?: string
}

interface BasicHeaders {
  Authorization: string
}

interface DepthHeaders {
  Authorization: string
  Depth: string
}

interface PutHeaders {
  Authorization: string
  'Content-Type': string
  'If-Match'?: string
  'If-None-Match'?: string
}

export class WebDavService {
  private readonly context: Context
  private readonly config: AppConfig
  private readonly rootDir: string
  private readonly cacheDir: string
  private readonly outboxDir: string
  private readonly pendingInboxPath: string
  private readonly statePath: string

  constructor(context: Context, config: AppConfig) {
    this.context = context
    this.config = config
    this.rootDir = `${context.filesDir}/org-tasks-webdav`
    this.cacheDir = `${this.rootDir}/cache`
    this.outboxDir = `${this.rootDir}/outbox`
    this.pendingInboxPath = `${this.outboxDir}/inbox.pending.org`
    this.statePath = `${this.rootDir}/sync-state.json`
  }

  getLocalDir(): string {
    return this.cacheDir
  }

  getCachedFiles(): WebDavCachedFile[] {
    const pending = FileService.readFileIfExists(this.pendingInboxPath).length > 0
    const files: WebDavCachedFile[] = []
    for (const file of FileService.listOrgFiles(this.cacheDir)) {
      files.push({
        relativePath: file.relativePath,
        localMtime: file.localMtime,
        taskCount: file.taskCount,
        status: pending && file.relativePath === this.config.inboxFile ? 'pending' : 'synced'
      })
    }
    return files
  }

  readCachedFile(relativePath: string): string {
    if (!this.isSafeFileName(relativePath)) return ''
    return FileService.readFileIfExists(`${this.cacheDir}/${relativePath}`)
  }

  async testConnection(): Promise<WebDavResult> {
    const validationError = this.validate()
    if (validationError) return this.failure(validationError)
    try {
      const files = await this.listOrgFiles()
      return { ok: true, localDir: this.cacheDir, downloaded: files.length, message: `连接成功，找到 ${files.length} 个 org 文件` }
    } catch (e) {
      return this.failure(this.toMessage(e))
    }
  }

  async syncToCache(): Promise<WebDavResult> {
    const validationError = this.validate()
    if (validationError) return this.failure(validationError)
    if (!FileService.ensureDir(this.cacheDir) || !FileService.ensureDir(this.outboxDir)) {
      return this.failure('无法创建 WebDAV 本地缓存目录')
    }

    try {
      const remotePaths = await this.listOrgFiles()
      const states: WebDavFileState[] = []
      for (const relativePath of remotePaths) {
        const remote = await this.getFile(relativePath)
        if (!remote.exists) throw new Error(`远端文件不存在: ${relativePath}`)
        const localPath = this.cachePath(relativePath)
        const parent = localPath.substring(0, localPath.lastIndexOf('/'))
        if (!FileService.ensureDir(parent) || !FileService.writeFileAtomic(localPath, remote.content)) {
          throw new Error(`无法写入本地缓存: ${relativePath}`)
        }
        states.push({ relativePath, remoteEtag: remote.etag, lastSyncedAt: Date.now() })
      }

      // Delete only stale cache files after a complete successful listing and download.
      for (const file of FileService.listFiles(this.cacheDir)) {
        if (file.endsWith('.org') && remotePaths.indexOf(file) < 0) {
          FileService.removeFile(`${this.cacheDir}/${file}`)
        }
      }

      const flush = await this.flushPendingInbox()
      if (!flush.ok) return flush
      if (flush.downloaded > 0) {
        const inbox = await this.getFile(this.config.inboxFile)
        if (inbox.exists && !FileService.writeFileAtomic(this.cachePath(this.config.inboxFile), inbox.content)) {
          return this.failure('无法更新本地 inbox 缓存')
        }
        states.push({ relativePath: this.config.inboxFile, remoteEtag: inbox.etag, lastSyncedAt: Date.now() })
      }

      this.saveState({ files: states })
      return { ok: true, localDir: this.cacheDir, downloaded: remotePaths.length, message: `已下载 ${remotePaths.length} 个 org 文件` }
    } catch (e) {
      return this.failure(this.toMessage(e))
    }
  }

  async saveTask(taskContent: string): Promise<WebDavResult> {
    if (!FileService.ensureDir(this.outboxDir) || !FileService.appendToFile(this.pendingInboxPath, taskContent)) {
      return this.failure('无法保存待上传任务')
    }
    return this.syncToCache()
  }

  private async flushPendingInbox(): Promise<WebDavResult> {
    const pending = FileService.readFileIfExists(this.pendingInboxPath)
    if (!pending) return { ok: true, localDir: this.cacheDir, downloaded: 0, message: '' }

    const remote = await this.getFile(this.config.inboxFile)
    if (remote.exists && !remote.etag) {
      return this.failure('服务器未提供 inbox.org 的 ETag，待上传任务已保留以避免覆盖远端内容')
    }
    const ifMatch = remote.exists ? remote.etag : ''
    const response = await this.request(
      this.fileUrl(this.config.inboxFile),
      'PUT',
      `${remote.content}${pending}`,
      '',
      ifMatch,
      !remote.exists
    )
    if (response.responseCode === 412) return this.failure('远端 inbox.org 已变更，待上传任务已保留')
    if (response.responseCode !== 200 && response.responseCode !== 201 && response.responseCode !== 204) {
      return this.failure(`上传 inbox.org 失败（HTTP ${response.responseCode}）`)
    }
    if (!FileService.removeFile(this.pendingInboxPath)) return this.failure('任务已上传，但无法清理待上传队列')
    return { ok: true, localDir: this.cacheDir, downloaded: 1, message: '' }
  }

  private async listOrgFiles(): Promise<string[]> {
    const response = await this.request(this.baseUrl(), 'PROPFIND', '', '1')
    if (response.responseCode !== 207) throw new Error(`列出 WebDAV 文件失败（HTTP ${response.responseCode}）`)

    const result = this.responseText(response.result)
    const fileNames = new Set<string>()
    const hrefMatches = result.match(/<[^>]*href[^>]*>[\s\S]*?<\/[^>]*href>/gi)
    if (!hrefMatches) return []
    for (const hrefMarkup of hrefMatches) {
      const href = hrefMarkup.replace(/<[^>]*>/g, '')
      const relativePath = this.relativePath(this.decodeXml(href))
      if (relativePath && relativePath.endsWith('.org')) fileNames.add(relativePath)
    }
    return Array.from(fileNames)
  }

  private async getFile(relativePath: string): Promise<RemoteFile> {
    const response = await this.request(this.fileUrl(relativePath), 'GET')
    if (response.responseCode === 404) return { exists: false, content: '', etag: '' }
    if (response.responseCode !== 200) throw new Error(`下载 ${relativePath} 失败（HTTP ${response.responseCode}）`)
    return { exists: true, content: this.responseText(response.result), etag: this.header(response.header, 'etag') }
  }

  private async request(
    url: string,
    method: string,
    extraData?: string,
    depth?: string,
    ifMatch?: string,
    ifNoneMatch: boolean = false
  ): Promise<http.HttpResponse> {
    const client = http.createHttp()
    const authorization = `Basic ${this.authorization()}`
    const basicHeaders: BasicHeaders = { Authorization: authorization }
    let headers: Object = basicHeaders
    if (depth) {
      const depthHeaders: DepthHeaders = { Authorization: authorization, Depth: depth }
      headers = depthHeaders
    } else if (ifMatch) {
      const putHeaders: PutHeaders = {
        Authorization: authorization,
        'Content-Type': 'text/plain; charset=utf-8',
        'If-Match': ifMatch
      }
      headers = putHeaders
    } else if (ifNoneMatch) {
      const putHeaders: PutHeaders = {
        Authorization: authorization,
        'Content-Type': 'text/plain; charset=utf-8',
        'If-None-Match': '*'
      }
      headers = putHeaders
    } else if (method === 'PUT') {
      const putHeaders: PutHeaders = { Authorization: authorization, 'Content-Type': 'text/plain; charset=utf-8' }
      headers = putHeaders
    }
    try {
      return await client.request(url, {
        method: method as http.RequestMethod,
        extraData,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 30000
      })
    } finally {
      client.destroy()
    }
  }

  private validate(): string {
    if (!this.config.webdavUrl.trim()) return '请填写 WebDAV 目录地址'
    if (!this.config.webdavUrl.trim().startsWith('https://')) return 'WebDAV 地址必须使用 HTTPS'
    if (!this.config.webdavUsername.trim() || !this.config.webdavPassword) return '请填写 WebDAV 用户名和密码'
    if (!this.config.inboxFile.trim().endsWith('.org')) return '新增任务文件必须是 .org 文件'
    return ''
  }

  private baseUrl(): string {
    const url = this.config.webdavUrl.trim()
    return url.endsWith('/') ? url : `${url}/`
  }

  private fileUrl(relativePath: string): string {
    return `${this.baseUrl()}${relativePath.split('/').map((part: string) => encodeURIComponent(part)).join('/')}`
  }

  private cachePath(relativePath: string): string {
    return `${this.cacheDir}/${relativePath}`
  }

  private isSafeFileName(value: string): boolean {
    return value.length > 0 && !value.includes('/') && !value.includes('\\') && !value.includes('..')
  }

  private relativePath(href: string): string {
    const cleanHref = href.replace(/[?#].*$/, '')
    const basePath = this.urlPath(this.baseUrl())
    const hrefPath = this.urlPath(cleanHref)
    if (!hrefPath.startsWith(basePath)) return ''
    const rawPath = hrefPath.substring(basePath.length).replace(/^\/+|\/+$/g, '')
    if (!rawPath) return ''
    const parts = rawPath.split('/')
    for (const part of parts) {
      if (!part || part === '.' || part === '..') return ''
    }
    try {
      return parts.map((part: string) => decodeURIComponent(part)).join('/')
    } catch {
      return ''
    }
  }

  private urlPath(url: string): string {
    const schemeIndex = url.indexOf('://')
    if (schemeIndex < 0) return url
    const pathIndex = url.indexOf('/', schemeIndex + 3)
    return pathIndex < 0 ? '/' : url.substring(pathIndex)
  }

  private authorization(): string {
    const value = `${this.config.webdavUsername}:${this.config.webdavPassword}`
    const bytes = util.TextEncoder.create().encode(value)
    return new util.Base64Helper().encodeToStringSync(bytes)
  }

  private responseText(value: string | Object | ArrayBuffer): string {
    if (typeof value === 'string') return value
    if (value instanceof ArrayBuffer) return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(value))
    return ''
  }

  private header(headers: Object, name: string): string {
    const values = headers as ResponseHeaders
    if (name === 'etag') return values.etag || values.ETag || ''
    return ''
  }

  private decodeXml(value: string): string {
    return value.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
  }

  private saveState(state: WebDavState): void {
    if (!FileService.writeFileAtomic(this.statePath, JSON.stringify(state))) {
      console.error('写入 WebDAV 同步状态失败')
    }
  }

  private toMessage(error: Object): string {
    return error instanceof Error ? error.message : `WebDAV 请求失败: ${JSON.stringify(error)}`
  }

  private failure(message: string): WebDavResult {
    return { ok: false, localDir: this.cacheDir, downloaded: 0, message }
  }
}
