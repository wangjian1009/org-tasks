import { router } from '@kit.ArkUI'

interface WorkspaceItem {
  title: string
  description: string
  route: string
  accent: string
}

@Entry
@Component
struct Workspace {
  private items: WorkspaceItem[] = [
    { title: '同步中心', description: '查看状态并同步到系统日历', route: 'pages/Index', accent: '#175C43' },
    { title: '日程', description: '按计划与截止时间查看任务', route: 'pages/Agenda', accent: '#1F5E8C' },
    { title: '笔记本', description: '浏览 org 文件与其中的任务', route: 'pages/Files', accent: '#7A4D16' },
    { title: '搜索', description: '按标题、正文、标签或状态筛选', route: 'pages/Search', accent: '#6A4C93' },
    { title: '已保存搜索', description: '重复使用常用的任务筛选', route: 'pages/SavedSearches', accent: '#8A3D5B' },
    { title: '设置', description: '配置仓库、WebDAV、日历和后台同步', route: 'pages/Settings', accent: '#34423B' }
  ]

  build() {
    Column() {
      Row() {
        Button('返回')
          .fontSize(14)
          .backgroundColor('#FFFFFF')
          .fontColor('#34423B')
          .onClick(() => router.back())
        Column() {
          Text('工作区')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
          Text('所有任务工作流')
            .fontSize(12)
            .fontColor('#65746B')
            .margin({ top: 2 })
        }
        .margin({ left: 12 })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 16 })

      List({ space: 1 }) {
        ForEach(this.items, (item: WorkspaceItem) => {
          ListItem() {
            Row() {
              Column() {
                Text(item.title)
                  .fontSize(17)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(item.accent)
                Text(item.description)
                  .fontSize(13)
                  .fontColor('#65746B')
                  .margin({ top: 5 })
              }
              .layoutWeight(1)
              Text('进入')
                .fontSize(13)
                .fontColor(item.accent)
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F7F8F7')
  }
}
