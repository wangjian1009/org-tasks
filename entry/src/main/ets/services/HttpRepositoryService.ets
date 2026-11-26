import { Context } from '@kit.AbilityKit'
import { url } from '@kit.ArkTS'
import { defaultSyncOptions, normalizeSyncOptions } from 'liborg_tasks_harmony.so'
import { AppConfig, RepoConfig } from '../models/OrgTask'
import { SYSTEM_REPOSITORY_ID } from '../models/SystemRepository'
import { AppConfigService } from './AppConfigService'
import { CredentialService } from './CredentialService'
import { CoreHttpUiRequest, CoreHttpUiResponse, NativeCoreService } from './NativeCoreService'
import { RepositorySetupService } from './RepositorySetupService'
import { RepositorySyncService, SyncStartPolicy } from './RepositorySyncService'

interface RepositoryInput {
  id?: string
  name?: string
  rootDirectory?: string
  webdavEnabled?: boolean
  webdavUrl?: string
  webdavUsername?: string
  webdavPassword?: string
  excludedDirectories?: string[]
}

interface RepositoryView {
  id: string
  name: string
  rootDirectory: string
  webdavEnabled: boolean
  webdavUrl: string
  webdavUsername: string
  excludedDirectories: string[]
  webdavCleanupPending: boolean
}

interface RepositoryErrorDetail { code: string; message: string }
interface RepositoryErrorBody { error: RepositoryErrorDetail }

const STRING_FIELDS: string[] = ['id', 'name', 'rootDirectory', 'webdavUrl', 'webdavUsername', 'webdavPassword']

class RepositoryRequestError extends Error {
  readonly status: number
  readonly code: string

  constructor(status: number, code: string, message: string) {
    super(message)
    this.status = status
    this.code = code
  }
}

function invalid(message: string): RepositoryRequestError {
  return new RepositoryRequestError(400, 'invalidInput', message)
}

function ensureActive(active: () => boolean): void {
  if (!active()) throw new RepositoryRequestError(503, 'unavailable', '测试服务已关闭或请求已超时')
}

function view(repo: RepoConfig): RepositoryView {
  return {
    id: repo.id, name: repo.name, rootDirectory: repo.rootDirectory,
    webdavEnabled: repo.webdavEnabled, webdavUrl: repo.webdavUrl, webdavUsername: repo.webdavUsername,
    excludedDirectories: repo.excludedDirectories, webdavCleanupPending: !!repo.webdavCleanupPending
  }
}

function inputFor(request: CoreHttpUiRequest): RepositoryInput {
  let input: RepositoryInput
  try { input = JSON.parse(request.body) as RepositoryInput }
  catch (_) { throw invalid('请求必须为 JSON 对象') }
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw invalid('请求必须为 JSON 对象')
  const fields = Object.keys(input)
  const values = input as Record<string, Object>
  for (const field of fields) {
    const value = values[field]
    if (STRING_FIELDS.includes(field) && typeof value === 'string') continue
    if (field === 'webdavEnabled' && typeof value === 'boolean') continue
    if (field === 'excludedDirectories' && Array.isArray(input.excludedDirectories) &&
      input.excludedDirectories.every(item => typeof item === 'string')) continue
    throw invalid('仓库字段或字段类型无效')
  }
  if (request.method === 'POST') {
    if (input.id !== undefined) throw invalid('新仓库的 id 由应用分配')
  } else {
    if (!input.id || input.id !== input.id.trim()) throw invalid('必须指定有效的配置仓库 id')
    if (input.id === SYSTEM_REPOSITORY_ID) throw new RepositoryRequestError(409, 'invalidState', '系统仓库由应用管理')
    if (request.method === 'DELETE' && fields.length !== 1) throw invalid('删除请求只接受 id')
    if (request.method === 'PATCH' && fields.length < 2) throw invalid('修改请求须包含至少一个待修改字段')
  }
  return input
}

function configuredRepository(config: AppConfig, id: string): RepoConfig {
  const repo = config.repos.find(item => item.id === id)
  if (!repo) throw new RepositoryRequestError(404, 'notFound', '仓库不存在')
  return repo
}

function validateWebDavUrl(value: string): void {
  try {
    const endpoint = new url.URL(value)
    if (value.startsWith('https://') && endpoint.hostname && !endpoint.username && !endpoint.password &&
      !value.includes('?') && !value.includes('#') && !value.includes('\\')) return
  } catch (_) {}
  throw invalid('WebDAV 地址必须是 HTTPS 目录地址')
}

export class HttpRepositoryService {
  private static changing: boolean = false

  static async handle(context: Context, request: CoreHttpUiRequest, active: () => boolean): Promise<CoreHttpUiResponse> {
    try {
      ensureActive(active)
      if (request.method === 'GET') {
        const config = await AppConfigService.load(context, false)
        return { status: 200, body: JSON.stringify(config.repos.filter(repo => repo.id !== SYSTEM_REPOSITORY_ID).map(view)) }
      }
      if (!['POST', 'PATCH', 'DELETE'].includes(request.method)) {
        throw new RepositoryRequestError(405, 'invalidInput', '不支持此请求方法')
      }
      const input = inputFor(request)
      if (HttpRepositoryService.changing) throw new RepositoryRequestError(409, 'invalidState', '正在修改仓库配置')
      HttpRepositoryService.changing = true
      try {
        if (request.method === 'DELETE') {
          await RepositorySyncService.changeConfiguration(async (): Promise<void> => {
            await AppConfigService.removeRepository(context, input.id!, (current): void => {
              ensureActive(active)
              configuredRepository(current, input.id!)
            })
            await HttpRepositoryService.refreshWorkspace(context)
          })
          return { status: 200, body: JSON.stringify({ id: input.id }) }
        }
        const creating = request.method === 'POST'
        const repo = await HttpRepositoryService.save(context, input, creating, active)
        if ((creating && repo.webdavEnabled) || repo.webdavCleanupPending) HttpRepositoryService.queueSync(context, repo)
        return { status: creating ? 201 : 200, body: JSON.stringify(view(repo)) }
      } finally { HttpRepositoryService.changing = false }
    } catch (error) {
      const failure = error instanceof RepositoryRequestError ? error :
        new RepositoryRequestError(500, 'store', '仓库配置操作失败')
      const body: RepositoryErrorBody = { error: { code: failure.code, message: failure.message } }
      return { status: failure.status, body: JSON.stringify(body) }
    }
  }

  private static async save(context: Context, input: RepositoryInput, creating: boolean,
    active: () => boolean): Promise<RepoConfig> {
    let saved: RepoConfig | undefined
    const clearedCredentials: string[] = []
    await RepositorySyncService.changeConfiguration(async (): Promise<void> => {
      try {
        await AppConfigService.updateRepositories(context, async (config): Promise<boolean> => {
          ensureActive(active)
          const previous = creating ? AppConfigService.newRepository() : configuredRepository(config, input.id!)
          const repo = await HttpRepositoryService.merge(context, config, previous, input, creating)
          if (previous.webdavEnabled && !repo.webdavEnabled) clearedCredentials.push(repo.id)
          ensureActive(active)
          await RepositorySetupService.prepareDirectory(context, repo, creating)
          const index = config.repos.findIndex(item => item.id === repo.id)
          if (index < 0) config.repos.push(repo)
          else config.repos[index] = repo
          if (creating && !repo.webdavEnabled) {
            const files = await RepositorySetupService.initialize(context, config, repo)
            RepositorySetupService.bindEntries(config, repo, files)
          }
          ensureActive(active)
          saved = repo
          return true
        }, clearedCredentials)
      } finally { await HttpRepositoryService.refreshWorkspace(context) }
    })
    return saved!
  }

  private static async merge(context: Context, config: AppConfig, previous: RepoConfig, input: RepositoryInput,
    creating: boolean): Promise<RepoConfig> {
    const repo: RepoConfig = {
      id: previous.id, name: input.name?.trim() ?? previous.name,
      rootDirectory: input.rootDirectory?.trim() ?? (creating ?
        RepositorySetupService.managedDirectory(context, previous.id) : previous.rootDirectory),
      webdavEnabled: input.webdavEnabled ?? previous.webdavEnabled,
      webdavUrl: input.webdavUrl?.trim() ?? previous.webdavUrl,
      webdavUsername: input.webdavUsername?.trim() ?? previous.webdavUsername,
      webdavPassword: input.webdavPassword ?? '',
      excludedDirectories: previous.excludedDirectories,
      webdavCleanupPending: previous.webdavCleanupPending
    }
    if (!repo.rootDirectory.startsWith('/') || /[\x00-\x1f\x7f]/.test(repo.rootDirectory)) {
      throw invalid('本地目录必须是绝对路径')
    }
    if (config.repos.some(item => item.id !== repo.id && item.rootDirectory === repo.rootDirectory)) {
      throw new RepositoryRequestError(409, 'invalidState', '此本地目录已用于其他仓库')
    }
    if ((previous.webdavCleanupPending && (repo.webdavEnabled || repo.rootDirectory !== previous.rootDirectory)) ||
      (previous.webdavEnabled && !repo.webdavEnabled && repo.rootDirectory !== previous.rootDirectory)) {
      throw new RepositoryRequestError(409, 'invalidState', '变更同步方式时须先处理原目录的同步状态')
    }
    if (previous.webdavEnabled && !repo.webdavEnabled) {
      repo.webdavUrl = ''
      repo.webdavUsername = ''
      repo.webdavPassword = ''
      repo.excludedDirectories = []
      repo.webdavCleanupPending = true
      return repo
    }
    if (repo.webdavEnabled || input.webdavUrl) validateWebDavUrl(repo.webdavUrl)
    if (repo.webdavEnabled && (!repo.webdavUsername || !(input.webdavPassword ??
      (creating ? '' : await CredentialService.getWebDavPassword(repo.id))))) {
      throw invalid('启用 WebDAV 需要用户名和密码')
    }
    if (input.webdavPassword === '') throw invalid('WebDAV 密码不能为空')
    if (input.excludedDirectories !== undefined) {
      try { repo.excludedDirectories = (await normalizeSyncOptions({ excludedDirectories: input.excludedDirectories })).excludedDirectories }
      catch (_) { throw invalid('同步过滤目录无效') }
    } else if (creating) {
      repo.excludedDirectories = (await defaultSyncOptions()).excludedDirectories
    }
    return repo
  }

  private static async refreshWorkspace(context: Context): Promise<void> {
    const current = await AppConfigService.load(context, false)
    await NativeCoreService.workspaceFor(current.repos, current.todoDefaults, current.coreSettings)
  }

  private static queueSync(context: Context, repo: RepoConfig): void {
    const source = repo.webdavCleanupPending ? 'manual' : 'repositoryCreated'
    const result = RepositorySyncService.start(context, {
      source, policy: SyncStartPolicy.Wait, repositoryId: repo.id
    })
    if (result.kind === 'rejected' || source === 'manual') return
    result.handle.completion.then(async (completion): Promise<void> => {
      if (completion.status === 'succeeded') await RepositorySetupService.finishSync(context, repo, 'repositoryCreated')
    }).catch((): void => { console.error('HTTP 新建仓库后初始化入口文件失败') })
  }
}
