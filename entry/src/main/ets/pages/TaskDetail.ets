import { router } from '@kit.ArkUI'
import { CoreTask } from '../services/NativeCoreService'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/Controls'
import { UiColor } from '../ui/Theme'

interface TaskParams { task?: CoreTask; parents?: string[] }

@Entry
@Component
struct TaskDetail {
  @State task: CoreTask | undefined = undefined
  @State parents: string[] = []
  @State metadataExpanded: boolean = true
  @State bodyExpanded: boolean = true
  @State drawerOpen: boolean = false

  aboutToAppear() {
    const params = router.getParams() as TaskParams
    this.task = params.task
    this.parents = params.parents || []
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
    Column() {
      AppShell({ title: '笔记', back: true, drawerOpen: $drawerOpen,
      actionIcon: $r('app.media.ui_add'), actionLabel: '新增任务', action: (): void => { router.pushUrl({ url: 'pages/AddTask' }) } }) {
        if (!this.task) {
          EmptyState({ title: '无法打开此笔记', detail: '请从日程、搜索或笔记本进入。' })
        } else {
          Scroll() {
            Column() {
              Text([this.task!.filePath, ...this.parents].join('  /  ')).fontSize(14).fontColor(UiColor.primary).width('100%')
                .padding({ left: 16, right: 16, top: 20, bottom: 12 })
                .onClick((): void => { router.pushUrl({ url: 'pages/FileDetail', params: { repoId: this.task!.repoId, path: this.task!.filePath } }) })
              Text(this.task!.heading).fontSize(24).fontWeight(FontWeight.Medium).fontColor(UiColor.text).width('100%')
                .padding({ left: 16, right: 16, top: 8, bottom: 20 }).copyOption(CopyOptions.LocalDevice)
              Divider().color(UiColor.outline)
              Row({ space: 24 }) {
                Image($r('app.media.ui_info')).width(24).height(24)
                Text('元数据').fontSize(14).fontColor(UiColor.secondary).layoutWeight(1)
                Image(this.metadataExpanded ? $r('app.media.ui_up') : $r('app.media.ui_down')).width(24).height(24).margin({ right: 16 })
              }.width('100%').padding({ left: 16, right: 4 }).height(52)
                .onClick(() => { this.metadataExpanded = !this.metadataExpanded })
              if (this.metadataExpanded) {
                this.metadata($r('app.media.ui_tags'), '标签', this.task!.tags.join('  '))
                this.metadata($r('app.media.ui_state'), '状态', this.task!.todoState)
                this.metadata($r('app.media.ui_priority'), '优先级', this.task!.priority ? `[#${this.task!.priority}]` : '')
                this.metadata($r('app.media.ui_calendar'), '计划时间', this.task!.scheduled)
                this.metadata($r('app.media.ui_deadline'), '截止时间', this.task!.deadline)
              }
              Divider().color(UiColor.outline)
              Row({ space: 24 }) {
                Image($r('app.media.ui_body')).width(24).height(24)
                Text('正文').fontSize(14).fontColor(UiColor.secondary).layoutWeight(1)
                Image(this.bodyExpanded ? $r('app.media.ui_up') : $r('app.media.ui_down')).width(24).height(24).margin({ right: 16 })
              }.width('100%').padding({ left: 16, right: 4 }).height(52)
                .onClick(() => { this.bodyExpanded = !this.bodyExpanded })
              if (this.bodyExpanded) {
                Text(this.task!.body.trim() || '没有正文内容').width('100%').fontSize(16).fontColor(UiColor.secondary).lineHeight(25)
                  .padding({ left: 16, right: 16, top: 4, bottom: 24 }).copyOption(CopyOptions.LocalDevice)
              }
              Divider().color(UiColor.outline)
              Text('只读笔记').fontSize(12).fontColor(UiColor.secondary).width('100%').padding(16)
            }.width('100%').padding({ bottom: 24 })
          }.width('100%').height('100%').align(Alignment.TopStart)
        }
      }
    }.width('100%').height('100%')
  }
}
