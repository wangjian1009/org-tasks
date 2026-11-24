import { PageNavigator } from './PageNavigator'
import { RepositoryCreationMode } from './PagePath'
import { UIContext } from '@kit.ArkUI'

export async function addRepository(context: UIContext, mode?: RepositoryCreationMode): Promise<void> {
  try {
    await PageNavigator.shared.pushPage(context, {
      url: 'pages/RepositorySettings', params: mode ? { repositoryCreation: mode } : undefined
    })
  }
  catch (_) {
    try { context.getPromptAction().showToast({ message: '无法打开仓库配置，请重试' }) }
    catch (_) { /* 页面已退出时不再显示提示。 */ }
  }
}
