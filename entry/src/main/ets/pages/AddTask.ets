// 新增任务页面
// 填写任务信息，写入 inbox.org

import { router } from '@kit.ArkUI'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'

@Entry
@Component
struct AddTask {
  @State heading: string = ''
  @State scheduled: string = ''
  @State deadline: string = ''
  @State tags: string = ''
  @State priority: string = ''
  @State saving: boolean = false
  @State message: string = ''
  @State config: AppConfig = DEFAULT_CONFIG

  aboutToAppear() {
    this.loadConfig()
  }

  async loadConfig() {
    try {
      const context = getContext(this)
      this.config = await AppConfigService.load(context)
    } catch (e) {
      console.error('加载配置失败:', JSON.stringify(e))
    }
  }

  async saveTask() {
    if (!this.heading.trim()) {
      this.message = '请输入任务标题'
      return
    }

    this.saving = true
    this.message = ''

    this.message = '新增任务需要 core editor 支持，当前未接入写入操作'
    this.saving = false
  }

  build() {
    Column() {
      Row() {
        Button('返回')
          .fontSize(14)
          .backgroundColor('#FFFFFF')
          .fontColor('#34423B')
          .onClick(() => router.back())
        Column() {
          Text('新增任务')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
          Text('写入 inbox.org，保留 org 工作流')
            .fontSize(12)
            .fontColor('#65746B')
            .margin({ top: 2 })
        }
        .margin({ left: 12 })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 16 })

      Scroll() {
        Column() {
          // 任务标题
          Text('标题 *')
            .fontSize(14)
            .fontColor('#666')
          TextInput({ placeholder: '任务标题', text: this.heading })
            .onChange((value: string) => { this.heading = value })
            .margin({ top: 8 })
            .height(44)

          // 优先级
          Text('优先级')
            .fontSize(14)
            .fontColor('#666')
            .margin({ top: 16 })
          Row() {
            ForEach(['A', 'B', 'C'], (p: string) => {
              Button(`[#${p}]`)
                .fontSize(14)
                .height(36)
                .backgroundColor(this.priority === p ? '#8A3D24' : '#FFFFFF')
                .fontColor(this.priority === p ? '#FFF' : '#34423B')
                .margin({ right: 8 })
                .onClick(() => {
                  this.priority = this.priority === p ? '' : p
                })
            })
          }
          .margin({ top: 8 })

          // 计划日期
          Text('计划日期')
            .fontSize(14)
            .fontColor('#666')
            .margin({ top: 16 })
          TextInput({ placeholder: 'YYYY-MM-DD', text: this.scheduled })
            .onChange((value: string) => { this.scheduled = value })
            .margin({ top: 8 })
            .height(44)

          // 截止日期
          Text('截止日期')
            .fontSize(14)
            .fontColor('#666')
            .margin({ top: 16 })
          TextInput({ placeholder: 'YYYY-MM-DD', text: this.deadline })
            .onChange((value: string) => { this.deadline = value })
            .margin({ top: 8 })
            .height(44)

          // 标签
          Text('标签')
            .fontSize(14)
            .fontColor('#666')
            .margin({ top: 16 })
          TextInput({ placeholder: '用逗号或空格分隔', text: this.tags })
            .onChange((value: string) => { this.tags = value })
            .margin({ top: 8 })
            .height(44)

          // 提示
          Text(this.config.webdavEnabled ? `将同步到 WebDAV: ${this.config.inboxFile}` : `将写入: ${this.config.orgDir}/${this.config.inboxFile}`)
            .fontSize(12)
            .fontColor('#999')
            .margin({ top: 24 })
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
      }
      .layoutWeight(1)

      // 消息
      if (this.message) {
        Text(this.message)
          .fontSize(14)
        .fontColor(this.message.includes('失败') ? '#B3261E' : '#357A55')
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 8 })
      }

      // 保存按钮
      Button(this.saving ? '保存中...' : '保存')
        .width('80%')
        .height(48)
        .fontSize(17)
        .backgroundColor('#175C43')
        .enabled(!this.saving)
        .margin({ bottom: 40 })
        .onClick(() => this.saveTask())
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F7F8F7')
  }
}
