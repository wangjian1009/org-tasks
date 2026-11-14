import { inlinePlanningLabel } from '../ui/TaskInlinePresentation'
import { TaskPriorityChoices } from './TaskPriorityChoices'
import { priorityColor, priorityBackground, priorityLabel } from '../ui/TaskPriorityPresentation'
import { TaskStateCategory, taskStateCategoryLabel } from '../ui/TaskStatePresentation'
import { CoreTask } from '../services/NativeCoreService'
import { EmptyState } from './Controls'
import { TitleText } from './TitleText'
import { TitleCounts } from './TitleCounts'
import { titleCounts } from '../ui/TitleCountPresentation'
import { OrgContentView } from './OrgContentView'
import { TaskLogView } from './TaskLogView'
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
  changePriority: (name: string | null) => Promise<boolean> = async () => false
  @State priorityOpen: boolean = false
  @State priorityMaximumWidth: number = 310
  @State metadataExpanded: boolean = true
  @State bodyExpanded: boolean = true
  @State logbookExpanded: boolean = false

  editingChanged() {
    if (this.editable) { this.bodyExpanded = true; this.priorityOpen = false }
  }

  async choosePriority(name: string | null) {
    if (this.disabled || this.editable) return
    if ((this.task?.priority?.name ?? null) === name || await this.changePriority(name)) this.priorityOpen = false
  }

  @Builder
  priorityPopup() {
    TaskPriorityChoices({ options: this.task?.priorityOptions ?? [], current: this.task?.priority ?? null,
      disabled: this.disabled, maximumWidth: this.priorityMaximumWidth, choose: (name: string | null): void => { this.choosePriority(name) } })
  }

  @Builder
  priorityMetadata() {
    Row({ space: 24 }) {
      Image($r('app.media.ui_priority')).width(24).height(24)
      Column({ space: 4 }) {
        Text('优先级').fontSize(12).fontColor(UiColor.secondary).width('100%')
        if (this.task?.priority) {
          Text(this.task!.priority!.name).fontSize(14).fontColor(priorityColor(this.task!.priority!.category))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 }).borderRadius(8)
            .backgroundColor(priorityBackground(this.task!.priority!.category))
        } else {
          Text('无').fontSize(16).fontColor(UiColor.secondary)
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Image($r('app.media.ui_next')).width(20).height(20).accessibilityLevel('no')
    }.width('100%').padding(16).constraintSize({ minHeight: 64 })
      .onAreaChange((_old: Area, area: Area) => { this.priorityMaximumWidth = Math.max(60, parseFloat(area.width.toString()) - 32) })
      .enabled(!this.disabled && !this.editable).accessibilityText(`${priorityLabel(this.task?.priority ?? null)}，点击修改`)
      .onClick(() => { this.priorityOpen = true })
      .bindPopup(this.priorityOpen, { builder: this.priorityPopup, placement: Placement.BottomLeft,
        targetSpace: 6, enableArrow: false, radius: 10, popupColor: UiColor.menu, backgroundBlurStyle: BlurStyle.NONE,
        mask: { color: Color.Transparent }, focusable: true, autoCancel: !this.disabled, onWillDismiss: !this.disabled,
        onStateChange: (event): void => { this.priorityOpen = event.isVisible } })
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
            this.priorityMetadata()
            this.metadata($r('app.media.ui_calendar'), '计划时间', this.task!.scheduled ? inlinePlanningLabel(this.task!.scheduled, this.task!.editContent.scheduledPlanning) : '')
            this.metadata($r('app.media.ui_deadline'), '截止时间', this.task!.deadline ? inlinePlanningLabel(this.task!.deadline, this.task!.editContent.deadlinePlanning) : '')
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
          if (!this.editable && this.task!.logs.length > 0) {
            Divider().color(UiColor.outline)
            Row({ space: 24 }) {
              Image($r('app.media.ui_body')).width(24).height(24)
              Text('日志').fontSize(14).fontColor(UiColor.secondary).layoutWeight(1)
              Image(this.logbookExpanded ? $r('app.media.ui_up') : $r('app.media.ui_down')).width(24).height(24).margin({ right: 16 })
            }.width('100%').padding({ left: 16, right: 4 }).height(52)
              .onClick(() => { this.logbookExpanded = !this.logbookExpanded })
            TaskLogView({ logs: this.task!.logs, expanded: this.logbookExpanded, contentBackground: UiColor.surface })
              .width('100%').padding({ left: 16, right: 16, bottom: this.logbookExpanded ? 4 : 0 })
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
