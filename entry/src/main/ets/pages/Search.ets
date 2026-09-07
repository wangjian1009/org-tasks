import { router } from '@kit.ArkUI'
import { OrgTask, AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { FileService } from '../services/FileService'
import { WebDavService } from '../services/WebDavService'
import { AppConfigService } from '../services/AppConfigService'

interface SearchRouteParams {
  query?: string
}

interface TaskRouteParams {
  task: OrgTask
}

@Entry
@Component
struct TaskSearch {
  @State query: string = ''
  @State stateFilter: string = '全部'
  @State tasks: OrgTask[] = []
  @State message: string = ''
  @State config: AppConfig = DEFAULT_CONFIG

  aboutToAppear() {
    const params = router.getParams() as SearchRouteParams
    this.query = params.query || ''
    this.loadTasks()
  }

  async loadTasks() {
    try {
      const context = getContext(this)
      this.config = await AppConfigService.load(context)
      const sourceDir = this.config.webdavEnabled
        ? new WebDavService(context, this.config).getLocalDir()
        : this.config.orgDir
      if (!FileService.dirExists(sourceDir)) {
        this.message = this.config.webdavEnabled ? '尚无 WebDAV 缓存，请先在同步中心同步' : '尚未找到 org 文件目录'
        return
      }
      const parsed = await FileService.parseAllTasks(sourceDir)
      this.tasks = parsed.tasks
      this.message = parsed.errors.length > 0 ? `有 ${parsed.errors.length} 个文件无法读取` : ''
    } catch (e) {
      this.message = `读取任务失败: ${JSON.stringify(e)}`
    }
  }

  visibleTasks(): OrgTask[] {
    const keywords = this.query.trim().toLowerCase()
    return this.tasks.filter((task: OrgTask) => {
      const stateMatched = this.stateFilter === '全部' ||
        (this.stateFilter === '未完成' && task.todoState !== 'DONE') ||
        (this.stateFilter === '已完成' && task.todoState === 'DONE')
      if (!stateMatched) return false
      if (!keywords) return true
      const searchable = `${task.heading} ${task.body} ${task.tags.join(' ')} ${task.todoState} ${task.fileName}`.toLowerCase()
      return searchable.includes(keywords)
    })
  }

  openTask(task: OrgTask) {
    const params: TaskRouteParams = { task }
    router.pushUrl({ url: 'pages/TaskDetail', params })
  }

  build() {
    Column() {
      Row() {
        Button('工作区')
          .fontSize(14)
          .backgroundColor('#FFFFFF')
          .fontColor('#34423B')
          .onClick(() => router.pushUrl({ url: 'pages/Workspace' }))
        Column() {
          Text('搜索')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
          Text('标题、正文、标签、状态和文件名')
            .fontSize(12)
            .fontColor('#65746B')
            .margin({ top: 2 })
        }
        .margin({ left: 12 })
        .layoutWeight(1)
        Button('保存')
          .fontSize(14)
          .backgroundColor('#F2EDF9')
          .fontColor('#6A4C93')
          .onClick(() => router.pushUrl({ url: 'pages/SavedSearches', params: { query: this.query } }))
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 14 })

      TextInput({ placeholder: '输入关键词', text: this.query })
        .height(44)
        .backgroundColor('#FFFFFF')
        .margin({ left: 20, right: 20 })
        .onChange((value: string) => this.query = value)

      Row() {
        ForEach(['全部', '未完成', '已完成'], (item: string) => {
          Button(item)
            .fontSize(13)
            .height(36)
            .backgroundColor(this.stateFilter === item ? '#6A4C93' : '#FFFFFF')
            .fontColor(this.stateFilter === item ? '#FFFFFF' : '#34423B')
            .margin({ right: 8 })
            .onClick(() => this.stateFilter = item)
        })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 10 })

      Text(`${this.visibleTasks().length} 个匹配任务`)
        .fontSize(13)
        .fontColor('#65746B')
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 10 })

      if (this.message) {
        Text(this.message)
          .fontSize(13)
          .fontColor('#8A3D24')
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 10 })
      }

      if (this.visibleTasks().length === 0 && !this.message) {
        Column() {
          Text('没有匹配的任务')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
          Text('尝试使用不同关键词，或调整状态筛选。')
            .fontSize(13)
            .fontColor('#65746B')
            .margin({ top: 8 })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 1 }) {
          ForEach(this.visibleTasks(), (task: OrgTask) => {
            ListItem() {
              Column() {
                Row() {
                  Text(task.todoState || '任务')
                    .fontSize(11)
                    .fontColor(task.todoState === 'DONE' ? '#357A55' : '#6A4C93')
                  Text(task.fileName)
                    .fontSize(12)
                    .fontColor('#8B938E')
                    .margin({ left: 8 })
                  Blank()
                  if (task.priority) {
                    Text(`优先级 ${task.priority}`)
                      .fontSize(12)
                      .fontColor('#8A3D24')
                  }
                }
                .width('100%')
                Text(task.heading)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 5 })
                if (task.tags.length > 0) {
                  Text(task.tags.map((tag: string) => `#${tag}`).join(' '))
                    .fontSize(12)
                    .fontColor('#65746B')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 5 })
                }
              }
              .width('100%')
              .padding({ left: 20, right: 20, top: 14, bottom: 14 })
              .backgroundColor('#FFFFFF')
              .onClick(() => this.openTask(task))
            }
          }, (task: OrgTask) => task.id)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F7F8F7')
  }
}
