import { localizedText } from '../ui/LocalizedText'
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
    try { context.getPromptAction().showToast({ message: localizedText($r('app.string.text_could_not_open_repository_configuration_please_try')) }) }
    catch (_) { /* 页面已退出时不再显示提示。 */ }
  }
}
