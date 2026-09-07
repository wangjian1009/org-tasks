import { router } from '@kit.ArkUI'
import { OrgTask } from '../models/OrgTask'

interface TaskRouteParams {
  task?: OrgTask
}

@Entry
@Component
struct TaskDetail {
  @State task: OrgTask | undefined = undefined
  @State metadataExpanded: boolean = true

  aboutToAppear() {
    const params = router.getParams() as TaskRouteParams
    this.task = params.task
  }

  taskState(): string {
    if (!this.task || !this.task.todoState) return '任务'
    return this.task.todoState
  }

  build() {
    Column() {
      Row() {
        Button('返回')
          .fontSize(14)
          .backgroundColor('#FFFFFF')
          .fontColor('#34423B')
          .onClick(() => router.back())
        Text('任务详情')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 12 })
          .layoutWeight(1)
        Button('新增')
          .fontSize(14)
          .backgroundColor('#E6F1EC')
          .fontColor('#175C43')
          .onClick(() => router.pushUrl({ url: 'pages/AddTask' }))
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 14 })

      if (!this.task) {
        Column() {
          Text('无法打开此任务')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
          Text('请从日程、搜索或文件任务列表进入。')
            .fontSize(13)
            .fontColor('#65746B')
            .margin({ top: 8 })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 16 }) {
            Text(this.taskState())
              .fontSize(12)
              .fontColor(this.task!.todoState === 'DONE' ? '#357A55' : '#1F5E8C')
              .backgroundColor(this.task!.todoState === 'DONE' ? '#E6F1EC' : '#E6F0F8')
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            Text(this.task!.heading)
              .fontSize(25)
              .fontWeight(FontWeight.Bold)
              .width('100%')

            Column() {
              Row() {
                Text('属性')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                Blank()
                Button(this.metadataExpanded ? '收起' : '展开')
                  .fontSize(12)
                  .backgroundColor('#FFFFFF')
                  .fontColor('#175C43')
                  .onClick(() => this.metadataExpanded = !this.metadataExpanded)
              }
              .width('100%')
              if (this.metadataExpanded) {
                if (this.task!.priority) {
                  Row() {
                    Text('优先级').fontSize(13).fontColor('#65746B').width(88)
                    Text(this.task!.priority).fontSize(14)
                  }
                  .width('100%')
                  .margin({ top: 14 })
                }
                if (this.task!.scheduled) {
                  Row() {
                    Text('计划').fontSize(13).fontColor('#65746B').width(88)
                    Text(this.task!.scheduled).fontSize(14)
                  }
                  .width('100%')
                  .margin({ top: 14 })
                }
                if (this.task!.deadline) {
                  Row() {
                    Text('截止').fontSize(13).fontColor('#65746B').width(88)
                    Text(this.task!.deadline).fontSize(14)
                  }
                  .width('100%')
                  .margin({ top: 14 })
                }
                if (this.task!.tags.length > 0) {
                  Row() {
                    Text('标签').fontSize(13).fontColor('#65746B').width(88)
                    Text(this.task!.tags.map((tag: string) => `#${tag}`).join(' ')).fontSize(14)
                  }
                  .width('100%')
                  .margin({ top: 14 })
                }
                Row() {
                  Text('来源').fontSize(13).fontColor('#65746B').width(88)
                  Text(this.task!.fileName).fontSize(14).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .margin({ top: 14 })
              }
            }
            .width('100%')
            .backgroundColor('#FFFFFF')
            .padding(16)

            Column() {
              Text('正文')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
              Text(this.task!.body || '没有正文内容')
                .fontSize(15)
                .fontColor('#34423B')
                .lineHeight(24)
                .width('100%')
                .margin({ top: 12 })
            }
            .width('100%')
            .backgroundColor('#FFFFFF')
            .padding(16)

            Text('任务编辑保留在 org 文件中；此页面按源文件内容展示，避免同步前改写未涉及的文本。')
              .fontSize(12)
              .fontColor('#65746B')
              .lineHeight(18)
              .width('100%')
          }
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 24 })
        }
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F7F8F7')
  }
}
