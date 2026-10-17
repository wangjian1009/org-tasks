import { router } from '@kit.ArkUI'
import { AppConfig, DEFAULT_CONFIG, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
import { CredentialService } from '../services/CredentialService'

interface WorkspaceItem {
  title: string
  description: string
  route: string
  accent: string
}

@Entry
@Component
struct Workspace {
  @State config: AppConfig = DEFAULT_CONFIG
  @State message: string = ''
  private items: WorkspaceItem[] = [
    { title: '新增任务', description: '选择仓库并写入 inbox 文件', route: 'pages/AddTask', accent: '#175C43' },
    { title: '同步中心', description: '查看状态并同步到系统日历', route: 'pages/Index', accent: '#175C43' },
    { title: '日程', description: '按计划与截止时间查看任务', route: 'pages/Agenda', accent: '#1F5E8C' },
    { title: '笔记本', description: '浏览 org 文件与其中的任务', route: 'pages/Files', accent: '#7A4D16' },
    { title: '搜索', description: '按标题、正文、标签或状态筛选', route: 'pages/Search', accent: '#6A4C93' },
    { title: '已保存搜索', description: '重复使用常用的任务筛选', route: 'pages/SavedSearches', accent: '#8A3D5B' }
  ]

  aboutToAppear() {
    this.loadConfig()
  }

  async loadConfig() {
    try {
      this.config = await AppConfigService.load(getContext(this))
    } catch (e) {
      this.message = '读取仓库列表失败'
    }
  }

  openRepository(repository: RepoConfig) {
    router.pushUrl({ url: 'pages/Settings', params: { repoId: repository.id } })
  }

  addRepository() {
    router.pushUrl({ url: 'pages/Settings' })
  }

  async removeRepository(repository: RepoConfig) {
    try {
      await CredentialService.clearWebDavPassword(repository.id)
      await AppConfigService.save(getContext(this), {
        repos: this.config.repos.filter((item: RepoConfig) => item.id !== repository.id),
        inboxFile: this.config.inboxFile,
        calendarName: this.config.calendarName,
        syncInterval: this.config.syncInterval
      })
      await this.loadConfig()
    } catch (e) {
      this.message = '删除仓库失败'
    }
  }

  build() {
    Column() {
      Row() {
        Button('返回').fontSize(14).backgroundColor('#FFFFFF').fontColor('#34423B').onClick(() => router.back())
        Column() {
          Text('工作区').fontSize(24).fontWeight(FontWeight.Bold)
          Text('仓库与任务工作流').fontSize(12).fontColor('#65746B')
        }
        .margin({ left: 12 })
        .layoutWeight(1)
        Button('添加仓库').fontSize(14).backgroundColor('#E6F1EC').fontColor('#175C43').onClick(() => this.addRepository())
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 16 })

      List({ space: 1 }) {
        ForEach(this.config.repos, (repository: RepoConfig) => {
          ListItem() {
            Row() {
              Column() {
                Text(repository.rootDirectory || '未设置目录').fontSize(16).fontWeight(FontWeight.Medium)
                Text(repository.webdavEnabled ? '已配置 WebDAV 远端' : '仅本地仓库')
                  .fontSize(12).fontColor('#65746B').margin({ top: 4 })
              }
              .layoutWeight(1)
              Button('配置').fontSize(12).backgroundColor('#FFFFFF').fontColor('#175C43')
                .onClick(() => this.openRepository(repository))
              Button('删除').fontSize(12).backgroundColor('#FFFFFF').fontColor('#B3261E')
                .margin({ left: 4 }).onClick(() => this.removeRepository(repository))
            }
            .width('100%')
            .padding({ left: 20, right: 14, top: 14, bottom: 14 })
            .backgroundColor('#FFFFFF')
          }
        }, (repository: RepoConfig) => repository.id)

        ForEach(this.items, (item: WorkspaceItem) => {
          ListItem() {
            Row() {
              Column() {
                Text(item.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor(item.accent)
                Text(item.description).fontSize(13).fontColor('#65746B').margin({ top: 5 })
              }
              .layoutWeight(1)
              Text('进入').fontSize(13).fontColor(item.accent)
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 18, bottom: 18 })
            .backgroundColor('#FFFFFF')
            .onClick(() => router.pushUrl({ url: item.route }))
          }
        }, (item: WorkspaceItem) => item.route)
      }
      .width('100%')
      .layoutWeight(1)
      if (this.message) {
        Text(this.message).fontSize(13).fontColor('#B3261E').padding(16)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F7F8F7')
  }
}
