import { UIContext } from '@kit.ArkUI'
import { AppConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { CoreHttpUiRequest, CoreHttpUiResponse, CoreWorkspace, CoreTask, NativeCoreService, fileResult } from './NativeCoreService'
import { PageNavigator } from './PageNavigator'
import { PagePath, PageRoute, PageParameters } from './PagePath'
import { MemoNavigation } from './MemoNavigation'
import { TaskInlineSession } from './TaskInlineService'

interface NavigationState { pages: PageRoute[] }
interface NavigationErrorBody { error: NavigationErrorDetail }
interface NavigationErrorDetail { code: string; message: string }
class NavigationError extends Error {
  readonly status: number
  constructor(status: number, message: string) { super(message); this.status = status }
}
const PAGE_NAMES: string[] = ['pages/Trash', 'pages/Inbox', 'pages/Today', 'pages/Planned', 'pages/Waiting', 'pages/Anytime', 'pages/Someday', 'pages/Memo', 'pages/Logbook', 'pages/Files', 'pages/Settings', 'pages/OrgFileDetail',
  'pages/RepositorySettings', 'pages/SyncLog', 'pages/ConflictFile', 'pages/MemoEdit']
const SECTIONS: string[] = ['', '废纸篓', '存储库', '文件入口', '任务状态分类', '应用程序', '关于小清单']

// 只处理导航协议与页面身份；数据读取沿用当前 Workspace，页面语义留在 Harmony。
export class HttpNavigationService {
  private static busy: boolean = false
  static async handle(context: UIContext, request: CoreHttpUiRequest, active: () => boolean): Promise<CoreHttpUiResponse> {
    const navigator = PageNavigator.shared
    let ownsRequest = false
    try {
      if (!active()) throw new NavigationError(503, '主窗口尚未就绪或测试服务已关闭')
      if (HttpNavigationService.busy || navigator.isNavigating()) throw new NavigationError(409, '正在切换页面')
      if (request.method === 'GET') return HttpNavigationService.snapshot()
      if (request.method !== 'PUT') throw new NavigationError(405, '不支持此请求方法')
      HttpNavigationService.busy = true; ownsRequest = true
      let state: NavigationState
      try { state = JSON.parse(request.body) as NavigationState }
      catch (_) { throw new NavigationError(400, '请求必须包含有效的页面路径') }
      HttpNavigationService.validate(state)
      const before = navigator.path
      const config = await AppConfigService.load(context.getHostContext()!, false)
      const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
      const pages: PageRoute[] = []
      for (const page of state.pages) pages.push(await HttpNavigationService.resolve(page, config, workspace))
      if (!active() || before !== navigator.path || !navigator.canLeaveExternally()) throw new NavigationError(409, '当前页面已变化或存在未完成的编辑')
      if (!await TaskInlineSession.end(true)) throw new NavigationError(409, '当前编辑无法保存')
      if (!active() || before !== navigator.path) throw new NavigationError(409, '当前页面已变化')
      if (!await navigator.setPath(context, new PagePath(pages))) throw new NavigationError(409, '页面跳转未完成，请读取当前路径后重试')
      return HttpNavigationService.snapshot()
    } catch (error) {
      const failure = error as Error
      const status = failure instanceof NavigationError ? failure.status : 500
      const body: NavigationErrorBody = { error: { code: status === 400 ? 'invalidInput' : status === 404 ? 'notFound' :
        status === 409 ? 'invalidState' : status === 503 ? 'unavailable' : 'store', message: failure.message } }
      return { status, body: JSON.stringify(body) }
    } finally { if (ownsRequest) HttpNavigationService.busy = false }
  }

  private static snapshot(): CoreHttpUiResponse {
    const state: NavigationState = { pages: PageNavigator.shared.path.pages }
    return { status: 200, body: JSON.stringify(state) }
  }

  private static validate(state: NavigationState): void {
    if (!state || typeof state !== 'object' || Array.isArray(state) || Object.keys(state).some(key => key !== 'pages') ||
      !Array.isArray(state.pages) || state.pages.length < 1 || state.pages.length > 32) throw new NavigationError(400, 'pages 必须包含 1 至 32 个页面')
    for (const page of state.pages) {
      if (!page || typeof page !== 'object' || Array.isArray(page) || !PAGE_NAMES.includes(page.url) ||
        Object.keys(page).some(key => key !== 'url' && key !== 'params')) throw new NavigationError(400, '页面名称或页面结构无效')
      const p = page.params
      if (p === undefined) {
        if (['pages/OrgFileDetail', 'pages/ConflictFile', 'pages/SyncLog', 'pages/MemoEdit'].includes(page.url)) throw new NavigationError(400, '页面缺少必要参数')
        continue
      }
      if (!p || typeof p !== 'object' || Array.isArray(p)) throw new NavigationError(400, '页面参数无效')
      let allowed: string[] = []
      switch (page.url) {
        case 'pages/Settings': allowed = ['section']; break
        case 'pages/ConflictFile': allowed = ['repoId', 'path']; break
        case 'pages/OrgFileDetail': allowed = ['repoId', 'path', 'syncId', 'repositoryName', 'backupTime', 'backupPath', 'focusTask']; break
        case 'pages/RepositorySettings': allowed = ['repoId']; break
        case 'pages/SyncLog': allowed = ['repoId', 'syncId']; break
        case 'pages/MemoEdit': allowed = ['task', 'create', 'memoId']; break
      }
      if (Object.keys(p).some(key => !allowed.includes(key))) throw new NavigationError(400, '页面包含不支持的参数')
      if ((p.repoId !== undefined && typeof p.repoId !== 'string') || (p.path !== undefined && typeof p.path !== 'string') ||
        (p.syncId !== undefined && typeof p.syncId !== 'string') || (p.repositoryName !== undefined && typeof p.repositoryName !== 'string') ||
        (p.backupPath !== undefined && typeof p.backupPath !== 'string') ||
        (p.backupTime !== undefined && p.backupTime !== null && (typeof p.backupTime !== 'number' || !Number.isFinite(p.backupTime)))) throw new NavigationError(400, '页面参数类型无效')
      if (p.section !== undefined && !SECTIONS.includes(p.section)) throw new NavigationError(400, '设置分组无效')
      if (['pages/OrgFileDetail', 'pages/ConflictFile'].includes(page.url) && (!p.repoId || !p.path)) throw new NavigationError(400, '必须指定 repoId 和 path')
      if (p.focusTask !== undefined) {
        const target = p.focusTask
        if (!target || typeof target !== 'object' || Array.isArray(target) || p.syncId !== undefined ||
          Object.keys(target).some(key => !['repoId', 'file', 'titles', 'occurrence'].includes(key)) ||
          target.repoId !== p.repoId || target.file !== p.path || !Array.isArray(target.titles) || !target.titles.length ||
          target.titles.some(title => typeof title !== 'string') ||
          (target.occurrence !== undefined && (!Number.isSafeInteger(target.occurrence) || target.occurrence < 1))) {
          throw new NavigationError(400, 'focusTask 必须是当前文件中的任务路径')
        }
      }
      if (page.url === 'pages/SyncLog' && !p.repoId) throw new NavigationError(400, '必须指定 repoId')
      if (page.url === 'pages/MemoEdit' && ((p.create !== undefined && typeof p.create !== 'boolean') ||
        (p.memoId !== undefined && (typeof p.memoId !== 'string' || !p.memoId)) ||
        [p.create === true, p.task !== undefined, p.memoId !== undefined].filter(value => value).length !== 1)) {
        throw new NavigationError(400, '备忘页必须指定 create=true、task 或 memoId 之一')
      }
    }
  }

  private static async resolve(page: PageRoute, config: AppConfig, workspace: CoreWorkspace): Promise<PageRoute> {
    const p = page.params ?? {}
    if (['pages/RepositorySettings', 'pages/SyncLog', 'pages/ConflictFile'].includes(page.url) && p.repoId &&
      !config.repos.some(repo => repo.id === p.repoId)) throw new NavigationError(404, '仓库不存在')
    if (page.url === 'pages/OrgFileDetail' && p.syncId) {
      const repo = (await workspace.repos()).find(repo => config.repos.some(item => item.id === p.repoId && item.rootDirectory === repo.rootDirectory))
      if (!repo) throw new NavigationError(404, '历史仓库不存在')
      try { await repo.historyFile(p.syncId, p.path!, false) }
      catch (_) { throw new NavigationError(404, '历史文件不存在') }
    } else if (['pages/OrgFileDetail', 'pages/ConflictFile'].includes(page.url)) {
      let repoId = p.repoId!
      if (page.url === 'pages/ConflictFile') {
        const configRepo = config.repos.find(repo => repo.id === p.repoId)!
        repoId = (await workspace.repos()).find(repo => repo.rootDirectory === configRepo.rootDirectory)?.id ?? ''
      }
      const files = fileResult((await workspace.query([{ type: 'file', query: { includeFiles: [{ repoId, path: p.path! }], includeIgnored: true } }]))[0])
      const file = files[0]
      if (!file) throw new NavigationError(404, '文件不存在')
    }
    if (page.url === 'pages/MemoEdit' && p.memoId) {
      const task = await MemoNavigation.findInConfig(config, p.memoId)
      if (!task) throw new NavigationError(404, '备忘不存在')
      return { url: page.url, params: { task } }
    }
    if (page.url === 'pages/MemoEdit' && p.task !== undefined) {
      const ref = p.task
      if (!ref || typeof ref !== 'object' || typeof ref.repoId !== 'string' || typeof ref.filePath !== 'string' || typeof ref.id !== 'string') throw new NavigationError(400, '备忘 task 必须指定 repoId、filePath 和 id')
      let task: CoreTask | undefined = undefined
      try { task = (await workspace.fileAt({ repoId: ref.repoId, file: ref.filePath, titles: [], occurrence: 1 })).nodes().find(item => item.id === ref.id) }
      catch (_) { throw new NavigationError(404, '备忘不存在') }
      if (!task) throw new NavigationError(404, '备忘不存在')
      const params: PageParameters = { task }
      return { url: page.url, params }
    }
    return page
  }
}
