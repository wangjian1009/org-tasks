// 新增任务页面
// 填写任务信息，写入 inbox.org

import { router } from '@kit.ArkUI'
import { FileService } from '../services/FileService'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { WebDavService } from '../services/WebDavService'
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

    // 解析标签
    const tags = this.tags
      ? this.tags.split(/[,，\s]+/).filter(t => t.length > 0)
      : undefined

    // 格式化日期为 org 格式
    const scheduledOrg = this.scheduled ? this.formatOrgDate(this.scheduled) : undefined
    const deadlineOrg = this.deadline ? this.formatOrgDate(this.deadline) : undefined

    if (this.config.webdavEnabled) {
      const content = FileService.formatNewTask(
        this.heading.trim(), scheduledOrg, deadlineOrg, tags, this.priority || undefined
      )
      const result = await new WebDavService(getContext(this), this.config).saveTask(content)
      if (result.ok) {
        this.message = '已上传到 ' + this.config.inboxFile
      } else if (result.message === '无法保存待上传任务') {
        this.message = '保存失败，请检查应用存储空间'
      } else {
        this.message = '已保存到待上传队列，将在下次同步时上传'
      }
    } else {
      const ok = FileService.addTaskToInbox(
        this.config.orgDir,
        this.config.inboxFile,
        this.heading.trim(),
        scheduledOrg,
        deadlineOrg,
        tags,
        this.priority || undefined
      )
      this.message = ok ? '已保存到 ' + this.config.inboxFile : '保存失败，请检查文件路径'
    }

    if (!this.message.includes('失败')) {
      // 延迟返回
      setTimeout(() => {
        router.back()
      }, 1000)
    }

    this.saving = false
  }

  /**
   * 将日期选择器的值转为 org 日期格式
   * 输入: "2026-08-12" 或 "2026-08-12T14:30"
   * 输出: "2026-08-12 Wed" 或 "2026-08-12 Wed 14:30"
   */
  formatOrgDate(dateStr: string): string {
    const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
    const d = new Date(dateStr)
    const year = d.getFullYear()
    const month = (d.getMonth() + 1).toString().padStart(2, '0')
    const day = d.getDate().toString().padStart(2, '0')
    const weekday = WEEKDAYS[d.getDay()]

    if (dateStr.includes('T') && dateStr.split('T')[1]) {
      const time = dateStr.split('T')[1]
      return `${year}-${month}-${day} ${weekday} ${time}`
    }
    return `${year}-${month}-${day} ${weekday}`
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('新增任务')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
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
                .backgroundColor(this.priority === p ? '#FF5722' : '#E0E0E0')
                .fontColor(this.priority === p ? '#FFF' : '#333')
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
          .fontColor(this.message.includes('失败') ? '#F44336' : '#4CAF50')
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 8 })
      }

      // 保存按钮
      Button(this.saving ? '保存中...' : '保存')
        .type(ButtonType.Capsule)
        .width('80%')
        .height(48)
        .fontSize(18)
        .enabled(!this.saving)
        .margin({ bottom: 40 })
        .onClick(() => this.saveTask())
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}
