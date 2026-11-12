import { TaskStateCategory, taskStateCategoryLabel } from '../ui/TaskStatePresentation'
import { CoreTask } from '../services/NativeCoreService'
import { EmptyState } from './Controls'
import { TitleText } from './TitleText'
import { TitleCounts } from './TitleCounts'
import { titleCounts } from '../ui/TitleCountPresentation'
import { OrgContentView } from './OrgContentView'
import { UiColor } from '../ui/Theme'
import { repeatSummary } from '../ui/TaskRepeatPresentation'

// 任务内容独立于路由页面，由任务编辑页展示。
@Component
export struct TaskEditor {
  @Prop task: CoreTask | undefined = undefined
  @Prop parents: string[] = []
  @Prop @Watch('editingChanged') editable: boolean = false
  @Prop disabled: boolean = false
  @Prop headingValue: string = ''
  @Prop bodyValue: string = ''
  headingChanged: (value: string) => void = () => {}
  bodyChanged: (value: string) => void = () => {}
  editRepeat: () => void = () => {}
  @State metadataExpanded: boolean = true
  @State bodyExpanded: boolean = true
  @State logbookExpanded: boolean = false

  editingChanged() {
    if (this.editable) this.bodyExpanded = true
  }

  @Builder
  metadata(icon: Resource, label: string, value: string) {
    Row({ space: 24 }) {
      Image(icon).width(24).height(24)
      Column({ space: 4 }) {
        Text(label).fontSize(12).fontColor(UiColor.secondary).width('100%')
        Text(value || '未设置').fontSize(16).fontColor(value ? UiColor.text : UiColor.secondary).width('100%')
          .copyOption(CopyOptions.LocalDevice)
      }.layoutWeight(1)
    }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 }).constraintSize({ minHeight: 64 })
  }

  build() {
    if (!this.task) {
      EmptyState({ title: '无法打开此任务', detail: '请从任务列表进入。' })
    } else {
      Scroll() {
        Column() {
          Text(this.task!.repoId === '<preview>' ? '合并预览 · 调整尚未应用' : [this.task!.filePath, ...this.parents].join('  /  ')).fontSize(14).fontColor(UiColor.primary).width('100%')
            .padding({ left: 16, right: 16, top: 20, bottom: 12 })
            .enabled(!this.editable && !this.disabled && this.task!.repoId !== '<preview>')
            .onClick((): void => { this.getUIContext().getRouter().pushUrl({ url: 'pages/FileDetail', params: { repoId: this.task!.repoId, path: this.task!.filePath } }) })
          if (this.editable) {
            TextInput({ text: this.headingValue, placeholder: '标题' })
              .width('100%').fontSize(24).fontColor(UiColor.text).backgroundColor(UiColor.field)
              .margin({ bottom: 20 }).enabled(!this.disabled)
              .onChange((value: string): void => { this.headingChanged(value) })
          } else {
            TitleText({ text: this.task!.heading, parts: this.task!.headingParts, textSize: 24, weight: FontWeight.Medium, copyable: true, showCounts: false, cancelled: this.task!.state?.category === TaskStateCategory.Cancel })
              .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 20 })
          }
          if (!this.editable && titleCounts(this.task!.headingParts).length > 0) {
            TitleCounts({ parts: this.task!.headingParts }).width('100%').padding({ left: 16, right: 16, bottom: 16 })
          }
          Divider().color(UiColor.outline)
          Row({ space: 24 }) {
            Image($r('app.media.ui_info')).width(24).height(24)
            Text('元数据').fontSize(14).fontColor(UiColor.secondary).layoutWeight(1)
            Image(this.metadataExpanded ? $r('app.media.ui_up') : $r('app.media.ui_down')).width(24).height(24).margin({ right: 16 })
          }.width('100%').padding({ left: 16, right: 4 }).height(52)
            .onClick(() => { this.metadataExpanded = !this.metadataExpanded })
          if (this.metadataExpanded) {
            this.metadata($r('app.media.ui_tags'), '标签', this.task!.tags.join('  '))
            this.metadata($r('app.media.ui_state'), '状态', (this.task!.state?.name || '') ? `${taskStateCategoryLabel(this.task!.state?.category)} · ${(this.task!.state?.name || '')}` : '备忘')
            this.metadata($r('app.media.ui_priority'), '优先级', this.task!.priority ? `[#${this.task!.priority}]` : '')
            this.metadata($r('app.media.ui_calendar'), '计划时间', this.task!.scheduled)
            this.metadata($r('app.media.ui_deadline'), '截止时间', this.task!.deadline)
            Row({ space: 12 }) {
              Image($r('app.media.ui_task_repeat')).width(24).height(24)
              Column({ space: 4 }) {
                Text('重复').fontSize(12).fontColor(UiColor.secondary).width('100%')
                Text(`计划：${repeatSummary(this.task!.editContent.scheduledRepeat?.rule)}`).fontSize(15).fontColor(UiColor.text).width('100%')
                if (this.task!.editContent.deadlineRepeat?.rule) {
                  Text(`截止：${repeatSummary(this.task!.editContent.deadlineRepeat?.rule)}`).fontSize(15).fontColor(UiColor.text).width('100%')
                }
              }.layoutWeight(1)
              Image($r('app.media.ui_next')).width(20).height(20).accessibilityLevel('no')
            }.width('100%').padding(16).constraintSize({ minHeight: 64 })
              .enabled(!this.disabled && !this.editable).onClick(() => { this.editRepeat() })
          }
          Divider().color(UiColor.outline)
          Row({ space: 24 }) {
            Image($r('app.media.ui_body')).width(24).height(24)
            Text('正文').fontSize(14).fontColor(UiColor.secondary).layoutWeight(1)
            Image(this.bodyExpanded ? $r('app.media.ui_up') : $r('app.media.ui_down')).width(24).height(24).margin({ right: 16 })
          }.width('100%').padding({ left: 16, right: 4 }).height(52)
            .onClick(() => { this.bodyExpanded = !this.bodyExpanded })
          if (this.bodyExpanded) {
            if (this.editable) {
              TextArea({ text: this.bodyValue, placeholder: '正文（Org 原文）' })
                .width('100%').constraintSize({ minHeight: 240 }).fontSize(16).fontColor(UiColor.text)
                .backgroundColor(UiColor.field).enabled(!this.disabled)
                .onChange((value: string): void => { this.bodyChanged(value) })
            } else if (this.task!.bodyHtml) {
              OrgContentView({ fragment: this.task!.bodyHtml, embedded: true }).width('100%')
            } else {
              Text('没有正文内容').width('100%').fontSize(16).fontColor(UiColor.secondary)
                .padding({ left: 16, right: 16, top: 4, bottom: 24 })
            }
          }
          if (!this.editable && this.task!.logbookHtml) {
            Divider().color(UiColor.outline)
            Row({ space: 24 }) {
              Image($r('app.media.ui_body')).width(24).height(24)
              Text('日志').fontSize(14).fontColor(UiColor.secondary).layoutWeight(1)
              Image(this.logbookExpanded ? $r('app.media.ui_up') : $r('app.media.ui_down')).width(24).height(24).margin({ right: 16 })
            }.width('100%').padding({ left: 16, right: 4 }).height(52)
              .onClick(() => { this.logbookExpanded = !this.logbookExpanded })
            if (this.logbookExpanded) {
              OrgContentView({ fragment: this.task!.logbookHtml, embedded: true }).width('100%')
            }
          }
          Divider().color(UiColor.outline)
          if (this.editable) {
            Text('保存标题与正文，元数据保持原值。').fontSize(12).fontColor(UiColor.secondary).width('100%').padding(16)
          }
        }.width('100%').padding({ bottom: 24 })
      }.width('100%').height('100%').align(Alignment.TopStart)
    }
  }
}
