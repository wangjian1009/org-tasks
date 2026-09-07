import { router } from '@kit.ArkUI'
import { FileService } from '../services/FileService'
import { OrgParser } from '../services/OrgParser'
import { WebDavService } from '../services/WebDavService'
import { AppConfigService } from '../services/AppConfigService'
import { OrgTask } from '../models/OrgTask'

interface FileDetailParams {
  path?: string
}

interface TaskRouteParams {
  task: OrgTask
}

@Entry
@Component
struct FileDetail {
  @State path: string = ''
  @State content: string = ''
  @State taskCount: number = 0
  @State mtime: number = 0
  @State message: string = ''
  @State tasks: OrgTask[] = []
  @State tab: string = '任务'

  aboutToAppear() {
    this.loadFile()
  }

  async loadFile() {
    const params = router.getParams() as FileDetailParams
    this.path = params.path || ''
    if (!this.isSafeFileName(this.path)) {
      this.message = '无效的文件路径'
      return
    }

    try {
      const context = getContext(this)
      const config = await AppConfigService.load(context)
      const sourceDir = config.webdavEnabled ? new WebDavService(context, config).getLocalDir() : config.orgDir
      this.content = config.webdavEnabled
        ? new WebDavService(context, config).readCachedFile(this.path)
        : FileService.readFileIfExists(`${sourceDir}/${this.path}`)
      if (!this.content) {
        this.message = '缓存中未找到此文件'
        return
      }
      this.tasks = OrgParser.parse(this.content, `${sourceDir}/${this.path}`)
      this.taskCount = this.tasks.length
      this.mtime = FileService.getMtime(`${sourceDir}/${this.path}`)
    } catch (e) {
      this.message = `读取文件失败: ${JSON.stringify(e)}`
    }
  }

  isSafeFileName(value: string): boolean {
    return value.length > 0 && !value.includes('/') && !value.includes('\\') && !value.includes('..')
  }

  formatTime(timestamp: number): string {
    if (timestamp <= 0) return '未知时间'
    const date = new Date(timestamp)
    return `${date.getFullYear()}-${(date.getMonth() + 1).toString().padStart(2, '0')}-${date.getDate().toString().padStart(2, '0')} ${date.getHours()}:${date.getMinutes().toString().padStart(2, '0')}`
  }

  openTask(task: OrgTask) {
    const params: TaskRouteParams = { task }
    router.pushUrl({ url: 'pages/TaskDetail', params })
  }

  build() {
    Column() {
      Row() {
        Button('返回')
          .fontSize(14)
          .backgroundColor('#FFFFFF')
          .fontColor('#34423B')
          .onClick(() => router.back())
        Text(this.path || '文件详情')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 12 })
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 12 })

      if (this.message) {
        Text(this.message)
          .fontSize(14)
          .fontColor('#C62828')
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 12 })
      } else {
        Text(`${this.taskCount} 个任务 · ${this.formatTime(this.mtime)}`)
          .fontSize(13)
          .fontColor('#666')
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 12 })
        Row() {
          ForEach(['任务', '原文'], (item: string) => {
            Button(item)
              .fontSize(13)
              .height(36)
              .backgroundColor(this.tab === item ? '#7A4D16' : '#FFFFFF')
              .fontColor(this.tab === item ? '#FFFFFF' : '#34423B')
              .margin({ right: 8 })
              .onClick(() => this.tab = item)
          })
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 10 })

        if (this.tab === '任务') {
          if (this.tasks.length === 0) {
            Column() {
              Text('这个文件没有 TODO 任务')
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
              Text('切换到原文可查看完整 org 内容。')
                .fontSize(13)
                .fontColor('#65746B')
                .margin({ top: 8 })
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            List({ space: 1 }) {
              ForEach(this.tasks, (task: OrgTask) => {
                ListItem() {
                  Column() {
                    Row() {
                      Text(task.todoState || '任务')
                        .fontSize(11)
                        .fontColor(task.todoState === 'DONE' ? '#357A55' : '#7A4D16')
                      if (task.priority) {
                        Text(`优先级 ${task.priority}`)
                          .fontSize(12)
                          .fontColor('#8A3D24')
                          .margin({ left: 8 })
                      }
                    }
                    .width('100%')
                    Text(task.heading)
                      .fontSize(16)
                      .fontWeight(FontWeight.Medium)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 5 })
                    if (task.scheduled || task.deadline) {
                      Text(`${task.scheduled ? `计划 ${task.scheduled}` : ''}${task.scheduled && task.deadline ? ' · ' : ''}${task.deadline ? `截止 ${task.deadline}` : ''}`)
                        .fontSize(12)
                        .fontColor('#65746B')
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
        } else {
          Scroll() {
            Text(this.content)
              .fontSize(14)
              .fontFamily('monospace')
              .fontColor('#333')
              .width('100%')
              .padding(16)
          }
          .layoutWeight(1)
          .backgroundColor('#FFFFFF')
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F7F8F7')
  }
}
