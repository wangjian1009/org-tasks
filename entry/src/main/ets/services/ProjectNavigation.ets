import { UIContext } from '@kit.ArkUI'
import { TaskInlineSession } from './TaskInlineService'

// 项目入口只传递真实文件身份；先结束现有编辑，保存失败时保留草稿与当前页面。
export class ProjectNavigation {
  static async open(context: UIContext, repoId: string, path: string): Promise<void> {
    try {
      if (!await TaskInlineSession.end(true)) return
      await context.getRouter().pushUrl({ url: 'pages/ProjectDetail', params: { repoId, path } })
    }
    catch (_) {
      try { context.getPromptAction().showToast({ message: '暂时无法打开项目，请重试。' }) }
      catch (_) { /* 页面已退出时不再显示提示。 */ }
    }
  }
}
