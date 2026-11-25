import { localizedText } from '../ui/LocalizedText'
import { Context } from '@kit.AbilityKit'
import { UIContext } from '@kit.ArkUI'
import { PagePath, PageRoute } from './PagePath'
import { AppDataManager } from './AppDataManager'
import { TaskView } from './TaskViewQueries'

export function primaryPage(view: TaskView | 'inbox'): PageRoute {
  if (view === 'inbox') return { url: 'pages/Inbox' }
  switch (view) {
    case 'today': return { url: 'pages/Today' }
    case 'planned': return { url: 'pages/Planned' }
    case 'waiting': return { url: 'pages/Waiting' }
    case 'anytime': return { url: 'pages/Anytime' }
    case 'someday': return { url: 'pages/Someday' }
    case 'memo': return { url: 'pages/Memo' }
    case 'logbook': return { url: 'pages/Logbook' }
  }
}

// 主窗口唯一的导航状态；平台 Router 只在这里执行路径变更。
export class PageNavigator {
  static readonly shared: PageNavigator = new PageNavigator()
  private state: PagePath = new PagePath([primaryPage('today')])
  private context: Context | undefined = undefined
  private app: AppDataManager | undefined = undefined
  private navigating: boolean = false
  private nativeDepth: number = 1
  private backHandlers: Map<string, () => boolean | Promise<boolean>> = new Map()

  get path(): PagePath { return this.state }
  isNavigating(): boolean { return this.navigating }
  private externalLeaveGuard: (() => boolean) | undefined = undefined
  watchExternalLeaveGuard(guard: () => boolean): () => void {
    this.externalLeaveGuard = guard
    return (): void => { if (this.externalLeaveGuard === guard) this.externalLeaveGuard = undefined }
  }
  canLeaveExternally(): boolean { return this.externalLeaveGuard?.() ?? true }
  watchBackHandler(route: string, handler: () => boolean | Promise<boolean>): () => void {
    this.backHandlers.set(route, handler)
    return (): void => { if (this.backHandlers.get(route) === handler) this.backHandlers.delete(route) }
  }

  // WindowStage 重新加载根页面时同时重建路径，不保留旧窗口历史。
  reset(page: PageRoute): void { this.restore(new PagePath([page])) }
  // WindowStage 只加载末级页面；祖先节点留待实际返回时加载。
  restore(path: PagePath): void { this.state = path; this.nativeDepth = 1 }

  start(context: Context): void {
    if (this.context) return
    this.context = context
    this.app = AppDataManager.shared(context)
    this.app.start().catch((): void => { console.error('读取导航共享数据失败') })
  }

  async close(): Promise<void> {
    this.context = undefined
    this.app = undefined
  }

  // 业务可直接设置完整路径；一级入口始终重建为单节点路径。
  async setPath(context: UIContext, path: PagePath): Promise<boolean> {
    return this.transition(context, async (): Promise<void> => {
      await this.replacePath(context, path)
    })
  }

  openPrimary(context: UIContext, page: PageRoute): Promise<boolean> {
    return this.setPath(context, new PagePath([page]))
  }

  pushPage(context: UIContext, page: PageRoute): Promise<boolean> {
    return this.transition(context, async (): Promise<void> => { await this.push(context, page) })
  }

  replacePage(context: UIContext, page: PageRoute): Promise<boolean> {
    return this.transition(context, async (): Promise<void> => {
      const previous = this.state
      this.state = previous.replace(page)
      try { await context.getRouter().replaceUrl(page) }
      catch (error) { this.state = previous; throw error as Error }
    })
  }

  back(context: UIContext): Promise<boolean> {
    return this.transition(context, async (): Promise<void> => {
      const handler = this.backHandlers.get(this.state.current.url)
      if (handler && await handler()) return
      if (this.state.depth > 1) {
        if (this.nativeDepth > 1) {
          context.getRouter().back()
          this.state = this.state.parent()
          this.nativeDepth--
        } else {
          await this.replacePath(context, this.state.parent())
        }
        return
      }
      // 不等待查询或网络：返回使用当前订阅快照，尚无结果时按空收件箱处理。
      const page = this.state.current
      const today = page.url === 'pages/Today'
      const target = page.url === 'pages/Inbox' ? 'today' : today || (this.app?.targetCount('inbox') ?? 0) > 0 ? 'inbox' : 'today'
      await this.replaceRoot(context, primaryPage(target))
    })
  }

  private async replaceRoot(context: UIContext, page: PageRoute): Promise<void> {
    await this.replacePath(context, new PagePath([page]))
  }

  private async replacePath(context: UIContext, path: PagePath): Promise<void> {
    const previous = this.state
    this.state = path
    try { await context.getRouter().replaceUrl(path.current) }
    catch (error) { this.state = previous; throw error as Error }
    context.getRouter().clear()
    this.nativeDepth = 1
  }

  private async push(context: UIContext, page: PageRoute): Promise<void> {
    const previous = this.state
    this.state = previous.push(page)
    try { await context.getRouter().pushUrl(page); this.nativeDepth++ }
    catch (error) { this.state = previous; throw error as Error }
  }

  private async transition(context: UIContext, action: () => Promise<void>): Promise<boolean> {
    if (this.navigating) return false
    this.navigating = true
    try { await action(); return true }
    catch (_) {
      try { context.getPromptAction().showToast({ message: localizedText($r('app.string.text_toggle_page_failed_please_try_again')) }) }
      catch (_) { /* 窗口关闭后不再显示提示。 */ }
      return false
    } finally { this.navigating = false }
  }
}
