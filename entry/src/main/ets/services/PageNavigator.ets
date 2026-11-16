import { Context } from '@kit.AbilityKit'
import { UIContext } from '@kit.ArkUI'
import { PagePath, PageRoute } from './PagePath'
import { AppConfigService } from './AppConfigService'
import { DataSetManager } from './DataSetManager'
import { FileTargetService } from './FileTargetService'
import { NativeCoreService } from './NativeCoreService'
import { TaskOverview } from './TaskViewQueries'

export function primaryPage(view: TaskOverview | 'inbox'): PageRoute {
  return view === 'inbox' ? { url: 'pages/Inbox' } : { url: 'pages/TaskOverview', params: { view } }
}

// 主窗口唯一的导航状态；平台 Router 只在这里执行路径变更。
export class PageNavigator {
  static readonly shared: PageNavigator = new PageNavigator()
  private state: PagePath = new PagePath([primaryPage('today')])
  private context: Context | undefined = undefined
  private dataSets: DataSetManager | undefined = undefined
  private stopData: (() => void) | undefined = undefined
  private inboxCount: number = 0
  private dataRevision: number = 0
  private dataLoading: Promise<void> | undefined = undefined
  private navigating: boolean = false
  private nativeDepth: number = 1
  private configurationChanged = (): void => { this.refreshInbox() }

  get path(): PagePath { return this.state }
  isNavigating(): boolean { return this.navigating }
  private externalLeaveGuard: (() => boolean) | undefined = undefined
  watchExternalLeaveGuard(guard: () => boolean): () => void {
    this.externalLeaveGuard = guard
    return (): void => { if (this.externalLeaveGuard === guard) this.externalLeaveGuard = undefined }
  }
  canLeaveExternally(): boolean { return this.externalLeaveGuard?.() ?? true }

  // WindowStage 重新加载根页面时同时重建路径，不保留旧窗口历史。
  reset(page: PageRoute): void { this.restore(new PagePath([page])) }
  // WindowStage 只加载末级页面；祖先节点留待实际返回时加载。
  restore(path: PagePath): void { this.state = path; this.nativeDepth = 1 }

  start(context: Context): void {
    if (this.context) return
    this.context = context
    AppConfigService.watchChanges(this.configurationChanged)
    this.refreshInbox()
  }

  private refreshInbox(): void {
    this.dataRevision++
    this.inboxCount = 0
    if (!this.dataLoading) {
      this.dataLoading = this.loadInbox().finally((): void => { this.dataLoading = undefined })
    }
  }

  private async loadInbox(): Promise<void> {
    let revision = -1
    while (this.context && revision !== this.dataRevision) {
      revision = this.dataRevision
      this.stopData?.(); this.stopData = undefined
      const previous = this.dataSets
      this.dataSets = undefined
      try {
        await previous?.close()
        const context = this.context
        if (!context) return
        const config = await AppConfigService.load(context, false)
        const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
        const target = FileTargetService.prepare(config, await workspace.repos(), 'inbox')
        if (!this.context || revision !== this.dataRevision) continue
        if (!target) return
        const manager = DataSetManager.create(context, 'page-navigation', [
          { name: 'inbox', query: target.task }, { name: 'file', query: target.file }
        ])
        this.dataSets = manager
        const update = (): void => {
          if (revision !== this.dataRevision || !manager.hasValidScope()) return
          this.inboxCount = FileTargetService.result(manager.get('inbox')?.data, manager.get('file')?.data)?.tasks.length ?? 0
        }
        this.stopData = manager.subscribe(update)
        await manager.start()
        update()
      } catch (_) {
        if (revision === this.dataRevision) console.error('读取导航收件箱数量失败')
      }
    }
  }

  async close(): Promise<void> {
    this.context = undefined
    this.dataRevision++
    AppConfigService.stopWatchingChanges(this.configurationChanged)
    await this.dataLoading
    this.stopData?.(); this.stopData = undefined
    await this.dataSets?.close(); this.dataSets = undefined
    this.inboxCount = 0
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
      const today = page.url === 'pages/TaskOverview' && (page.params?.view ?? 'today') === 'today'
      const target = page.url === 'pages/Inbox' ? 'today' : today || this.inboxCount > 0 ? 'inbox' : 'today'
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
      try { context.getPromptAction().showToast({ message: '切换页面失败，请重试' }) }
      catch (_) { /* 窗口关闭后不再显示提示。 */ }
      return false
    } finally { this.navigating = false }
  }
}
