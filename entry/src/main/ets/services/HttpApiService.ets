import { Context } from '@kit.AbilityKit'
import { AppConfigService } from './AppConfigService'
import { CoreWorkspace, NativeCoreService } from './NativeCoreService'

// 仅由 APP 的测试启动参数启用，不持久化、不提供普通用户入口。
export class HttpApiService {
  private static context: Context | undefined = undefined
  private static workspace: CoreWorkspace | undefined = undefined
  private static enabled: boolean = false
  private static queue: Promise<void> = Promise.resolve()
  private static configChanged: () => void = (): void => {
    HttpApiService.serialize(async (): Promise<void> => {
      if (HttpApiService.enabled) await HttpApiService.connect()
    }).catch((error: Error): void => { HttpApiService.report(error) })
  }

  static start(context: Context): Promise<void> {
    return HttpApiService.serialize(async (): Promise<void> => {
      HttpApiService.context = context
      HttpApiService.enabled = true
      AppConfigService.watchChanges(HttpApiService.configChanged)
      try { await HttpApiService.connect() }
      catch (error) {
        HttpApiService.enabled = false
        AppConfigService.stopWatchingChanges(HttpApiService.configChanged)
        throw error as Error
      }
    })
  }

  static stop(): Promise<void> {
    return HttpApiService.serialize(async (): Promise<void> => {
      HttpApiService.enabled = false
      AppConfigService.stopWatchingChanges(HttpApiService.configChanged)
      await HttpApiService.disconnect()
      HttpApiService.context = undefined
    })
  }

  private static serialize(action: () => Promise<void>): Promise<void> {
    const operation = HttpApiService.queue.then(action)
    HttpApiService.queue = operation.catch((): void => {})
    return operation
  }

  private static async connect(): Promise<void> {
    if (!HttpApiService.context) return
    const config = await AppConfigService.load(HttpApiService.context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    if (HttpApiService.workspace && HttpApiService.workspace !== workspace) await HttpApiService.disconnect()
    const info = await workspace.startHttpServer(8787)
    HttpApiService.workspace = workspace
    console.info(`APP HTTP 接口已启动：http://${info.address}`)
  }

  private static async disconnect(): Promise<void> {
    if (HttpApiService.workspace) await HttpApiService.workspace.stopHttpServer()
    HttpApiService.workspace = undefined
  }

  private static report(error: Error): void {
    console.error(`HTTP 接口启动失败：${error.message}`)
  }
}
