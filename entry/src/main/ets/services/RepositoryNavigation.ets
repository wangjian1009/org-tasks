import { UIContext } from '@kit.ArkUI'

export function addRepository(context: UIContext): void {
  context.showActionSheet({ title: '添加存储库', message: '', sheets: [
    { title: '本地存储库', action: (): void => {
      context.getRouter().pushUrl({ url: 'pages/RepositorySettings', params: { webdav: false } })
    } },
    { title: 'WebDAV 存储库', action: (): void => {
      context.getRouter().pushUrl({ url: 'pages/RepositorySettings', params: { webdav: true } })
    } }
  ] })
}
