import { router } from '@kit.ArkUI'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
import { coreErrorMessage, CoreBridgeError, CoreTask, NativeCoreService } from '../services/NativeCoreService'

interface TaskRouteParams {
  task: CoreTask
}

@Entry
@Component
struct Agenda {
  @State tasks: CoreTask[] = []
  @State filter: string = '全部'
  @State message: string = ''
  @State config: AppConfig = DEFAULT_CONFIG

  aboutToAppear() {
    this.loadTasks()
  }

  async loadTasks() {
    try {
      const context = getContext(this)
      this.config = await AppConfigService.load(context)
      const expression = this.filter === '计划'
        ? 's.ge.-100y'
        : this.filter === '截止'
          ? 'd.ge.-100y'
          : 's.ge.-100y or d.ge.-100y'
      const response = await NativeCoreService.searchWorkspace(this.config.repos, expression)
      this.tasks = response.tasks
      this.message = ''
    } catch (e) {
      this.message = `读取日程失败: ${coreErrorMessage(e as CoreBridgeError)}`
    }
  }

  visibleTasks(): CoreTask[] {
    return this.tasks
  }

  taskDate(task: CoreTask): string {
    if (task.deadline.length > 0 && task.scheduled.length > 0) return `计划 ${task.scheduled} · 截止 ${task.deadline}`
    if (task.deadline.length > 0) return `截止 ${task.deadline}`
    return `计划 ${task.scheduled}`
  }

  openTask(task: CoreTask) {
    const params: TaskRouteParams = { task }
    router.pushUrl({ url: 'pages/TaskDetail', params })
  }

  build() {
    Column() {
      Row() {
        Button('☰')
          .width(48)
          .height(48)
          .fontSize(26)
          .backgroundColor('#00000000')
          .fontColor('#26332D')
          .onClick(() => router.pushUrl({ url: 'pages/Workspace' }))
        Column() {
          Text('日程')
            .fontSize(22)
            .fontWeight(FontWeight.Medium)
          Text(this.filter === '全部' ? '计划与截止任务' : `${this.filter}任务`)
            .fontSize(12)
            .fontColor('#68726D')
            .margin({ top: 1 })
        }
        .margin({ left: 4 })
        .layoutWeight(1)
        Button('⌕')
          .width(44)
          .height(48)
          .fontSize(25)
          .backgroundColor('#00000000')
          .fontColor('#26332D')
          .onClick(() => router.pushUrl({ url: 'pages/Search' }))
        Button('↻')
          .width(44)
          .height(48)
          .fontSize(24)
          .backgroundColor('#00000000')
          .fontColor('#175C43')
          .onClick(() => this.loadTasks())
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .border({ width: { bottom: 1 }, color: '#D8DCD9' })

      Row() {
        ForEach(['全部', '计划', '截止'], (item: string) => {
          Button(item)
            .fontSize(13)
            .height(36)
            .backgroundColor(this.filter === item ? '#175C43' : '#FFFFFF')
            .fontColor(this.filter === item ? '#FFFFFF' : '#34423B')
            .margin({ right: 8 })
            .onClick(() => {
              this.filter = item
              this.loadTasks()
            })
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .border({ width: { bottom: 1 }, color: '#E1E4E1' })

      if (this.message) {
        Text(this.message)
          .fontSize(13)
          .fontColor('#8A3D24')
          .width('100%')
          .padding({ left: 20, right: 20, top: 12, bottom: 12 })
      }

      if (this.visibleTasks().length === 0 && !this.message) {
        Column() {
          Text('没有待展示的日程')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
          Text('为任务添加计划或截止时间后，它会显示在这里。')
            .fontSize(13)
            .fontColor('#65746B')
            .margin({ top: 8 })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 1 }) {
          ForEach(this.visibleTasks(), (task: CoreTask) => {
            ListItem() {
              Row({ space: 12 }) {
                Column()
                  .width(3)
                  .height(54)
                  .backgroundColor(task.deadline.length > 0 ? '#B75A3A' : '#1F6B54')
                Column() {
                  Text(task.heading)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${task.todoState || '任务'} · ${this.taskDate(task)}`)
                    .fontSize(12)
                    .fontColor('#65746B')
                    .margin({ top: 5 })
                  Text(task.fileName)
                    .fontSize(12)
                    .fontColor('#8B938E')
                    .margin({ top: 3 })
                }
                .layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 13, bottom: 13 })
              .backgroundColor('#FFFFFF')
              .border({ width: { bottom: 1 }, color: '#E0E2E0' })
              .onClick(() => this.openTask(task))
            }
        }, (task: CoreTask) => task.id)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F8F9F8')
  }
}
