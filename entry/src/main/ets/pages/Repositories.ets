import { router } from '@kit.ArkUI'
import { AppConfig, DEFAULT_CONFIG, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
import { CredentialService } from '../services/CredentialService'
import { CoreBridgeError, coreErrorMessage } from '../services/NativeCoreService'
import { AppShell } from '../components/AppShell'
import { EmptyState, MessageBar } from '../components/Controls'
import { repositoryName, UiColor } from '../ui/Theme'

@Entry
@Component
struct Repositories {
  @State config: AppConfig = DEFAULT_CONFIG
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State loading: boolean = true
  @State deleting: boolean = false

  onPageShow() { this.load() }
  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return this.deleting
  }

  async load() {
    try { this.config = await AppConfigService.load(getContext(this)); this.message = '' }
    catch (e) { this.message = `读取存储库失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.loading = false }
  }

  addRepository() {
    this.getUIContext().showActionSheet({ title: '新建存储库', message: '选择 Org 文件的来源', sheets: [
      { title: 'WebDAV', action: (): void => { router.pushUrl({ url: 'pages/RepositorySettings', params: { webdav: true } }) } },
      { title: '本地目录', action: (): void => { router.pushUrl({ url: 'pages/RepositorySettings', params: { webdav: false } }) } }
    ] })
  }

  confirmDelete(repo: RepoConfig) {
    this.getUIContext().showAlertDialog({ title: '删除存储库配置？', message: `将移除“${repositoryName(repo.rootDirectory)}”的配置和密码，保留本地 org 文件。`,
      primaryButton: { value: '取消', action: () => {} }, secondaryButton: { value: '删除', action: (): void => { this.remove(repo) } } })
  }

  async remove(repo: RepoConfig) {
    if (this.deleting) return
    this.deleting = true
    try {
      const current = await AppConfigService.load(getContext(this))
      await AppConfigService.save(getContext(this), { repos: current.repos.filter((item: RepoConfig) => item.id !== repo.id),
        inboxFile: current.inboxFile, calendarName: current.calendarName, syncInterval: current.syncInterval })
      await CredentialService.clearWebDavPassword(repo.id)
      await this.load()
    } catch (e) { this.message = `删除存储库失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.deleting = false }
  }

  build() {
    Column() {
      AppShell({ title: '存储库', activeRoute: 'pages/Repositories', drawerOpen: $drawerOpen, busy: this.deleting,
        fabLabel: '新建存储库', fabAction: (): void => { this.addRepository() } }) {
        Column() {
          MessageBar({ message: this.message, error: true })
          if (this.loading) {
            EmptyState({ title: '正在读取存储库', busy: true })
          } else if (this.config.repos.length === 0) {
            Column({ space: 20 }) {
              Text('为同步笔记本新建存储库').fontSize(20).fontColor(UiColor.text).textAlign(TextAlign.Center).margin({ bottom: 12 })
              Button('WebDAV').width('100%').height(64).fontSize(17).backgroundColor(UiColor.selected).fontColor(UiColor.onSelected)
                .onClick((): void => { router.pushUrl({ url: 'pages/RepositorySettings', params: { webdav: true } }) })
              Button('本地目录').width('100%').height(64).fontSize(17).backgroundColor(UiColor.selected).fontColor(UiColor.onSelected)
                .onClick((): void => { router.pushUrl({ url: 'pages/RepositorySettings', params: { webdav: false } }) })
            }.width('100%').padding(24).margin({ top: 24 })
          } else {
            List() {
              ForEach(this.config.repos, (repo: RepoConfig) => {
                ListItem() {
                  Row({ space: 16 }) {
                    Image(repo.webdavEnabled ? $r('app.media.ui_cloud') : $r('app.media.ui_folder')).width(28).height(28)
                    Column({ space: 6 }) {
                      Text(repositoryName(repo.rootDirectory)).fontSize(18).fontColor(UiColor.text).width('100%')
                      Text(repo.webdavEnabled ? repo.webdavUrl : '本地目录').fontSize(13).fontColor(UiColor.secondary).width('100%').maxLines(2)
                    }.layoutWeight(1).onClick((): void => { router.pushUrl({ url: 'pages/RepositorySettings', params: { repoId: repo.id } }) })
                    Button('删除').fontSize(12).height(40).backgroundColor(Color.Transparent).fontColor(UiColor.error)
                      .enabled(!this.deleting).onClick((): void => { this.confirmDelete(repo) })
                  }.width('100%').padding(16).border({ width: { bottom: 0.5 }, color: UiColor.outline })
                }
              }, (repo: RepoConfig) => JSON.stringify([repo.id, repo.rootDirectory, repo.webdavEnabled, repo.webdavUrl]))
            }.width('100%').layoutWeight(1).padding({ bottom: 88 })
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
