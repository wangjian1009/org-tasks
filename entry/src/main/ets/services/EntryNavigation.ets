import { Want } from '@kit.AbilityKit'
import { PagePath, PageRoute } from './PagePath'

interface EntryPath { pages: PageRoute[] }

// 外部入口只描述目标路径，不依赖任何页面先出现或完成数据加载。
export function entryNavigation(want: Want): PagePath | undefined {
  const parameters = want.parameters
  if (typeof parameters?.navigation === 'string') {
    try {
      const value = JSON.parse(parameters.navigation) as EntryPath
      if (!value || Object.keys(value).some(key => key !== 'pages') || !Array.isArray(value.pages)) return undefined
      const pages = value.pages
      const root = pages[0]
      if (!root || Object.keys(root).some(key => key !== 'url' && key !== 'params') ||
        root.url !== 'pages/Memo' || root.params !== undefined && Object.keys(root.params).length > 0) return undefined
      if (pages.length === 1) return new PagePath(pages)
      const target = pages[1]
      if (pages.length !== 2 || !target || target.url !== 'pages/MemoEdit' || !target.params ||
        Object.keys(target).some(key => key !== 'url' && key !== 'params') ||
        Object.keys(target.params).some(key => key !== 'create' && key !== 'memoId')) return undefined
      const p = target.params
      if (p.create === true && p.memoId === undefined || p.create === undefined && typeof p.memoId === 'string' && p.memoId.length > 0) return new PagePath(pages)
    } catch (_) { /* 无效外部路径不改变当前界面。 */ }
    return undefined
  }
  // 分享地址保存后回到收件箱。
  if (parameters?.page === 'inbox') return new PagePath([{ url: 'pages/Inbox' }])
  return undefined
}
