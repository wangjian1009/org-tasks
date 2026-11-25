import { localizedText } from '../ui/LocalizedText'
import { PageNavigator } from './PageNavigator'
import { PageRoute } from './PagePath'
import { UIContext } from '@kit.ArkUI'
import { TaskInlineSession } from './TaskInlineService'
import { AppConfigService } from './AppConfigService'
import { NativeCoreService, CoreTaskPath } from './NativeCoreService'

// 项目入口只传递真实文件身份；先结束现有编辑，保存失败时保留草稿与当前页面。
export class OrgFileNavigation {
  static async hasInternalTarget(context: UIContext, repoId: string, path: string, target: string): Promise<boolean> {
    const config = await AppConfigService.load(context.getHostContext()!, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const file = await workspace.fileAt({ repoId, file: path, titles: [] })
    return file.documentSections().some(section => section.linkTargets.some(destination => destination.target === target))
  }

  static async openInternal(context: UIContext, repoId: string, path: string, target: string): Promise<void> {
    const previous = PageNavigator.shared.path
    if (!await TaskInlineSession.end(true) || previous !== PageNavigator.shared.path ||
      !await OrgFileNavigation.hasInternalTarget(context, repoId, path, target) || previous !== PageNavigator.shared.path ||
      !await PageNavigator.shared.pushPage(context, { url: 'pages/OrgFileDetail', params: { repoId, path, focusLink: target } })) {
      throw new Error(localizedText($r('app.string.text_internal_link_target_changed_or_current_edit')))
    }
  }

  static async open(context: UIContext, repoId: string, path: string, primary: boolean = false,
    taskPath?: () => CoreTaskPath | undefined): Promise<boolean> {
    try {
      if (!await TaskInlineSession.end(true)) return false
      const focusTask = taskPath?.()
      if (taskPath && !focusTask?.file) return false
      const page: PageRoute = { url: 'pages/OrgFileDetail',
        params: focusTask ? { repoId: focusTask.repoId, path: focusTask.file!, focusTask } : { repoId, path } }
      return primary ? await PageNavigator.shared.openPrimary(context, page) : await PageNavigator.shared.pushPage(context, page)
    }
    catch (_) {
      try { context.getPromptAction().showToast({ message: localizedText($r('app.string.text_couldn_t_open_the_project_try_again')) }) }
      catch (_) { /* 页面已退出时不再显示提示。 */ }
      return false
    }
  }
}
