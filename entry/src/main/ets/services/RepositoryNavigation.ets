import { UIContext } from '@kit.ArkUI'

export async function addRepository(context: UIContext): Promise<void> {
  try { await context.getRouter().pushUrl({ url: 'pages/RepositorySettings' }) }
  catch (_) {
    try { context.getPromptAction().showToast({ message: '无法打开仓库配置，请重试' }) }
    catch (_) { /* 页面已退出时不再显示提示。 */ }
  }
}
