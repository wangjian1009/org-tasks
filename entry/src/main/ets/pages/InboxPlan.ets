import { router } from '@kit.ArkUI'
import { CoreTask } from '../services/NativeCoreService'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/Controls'
import { TaskEditor } from '../components/TaskEditor'
import { MemoEditor } from '../components/MemoEditor'
import { UiColor } from '../ui/Theme'

type PlanKind = 'task' | 'memo'
interface PlanParams { task?: CoreTask; parents?: string[] }

@Entry
@Component
struct InboxPlan {
  @State task: CoreTask | undefined = undefined
  @State parents: string[] = []
  @State kind: PlanKind = 'task'
  @State drawerOpen: boolean = false

  aboutToAppear() {
    const params = router.getParams() as PlanParams | undefined
    this.task = params?.task
    this.parents = params?.parents || []
  }

  @Builder
  kindButton(kind: PlanKind, label: string) {
    Button(label).layoutWeight(1).height(40).borderRadius(10)
      .backgroundColor(this.kind === kind ? UiColor.selected : UiColor.surface)
      .fontColor(this.kind === kind ? UiColor.primary : UiColor.secondary)
      .accessibilityText(`规划为${label}${this.kind === kind ? '，已选择' : ''}`)
      .onClick((): void => { this.kind = kind })
  }

  build() {
    Column() {
      AppShell({ title: '规划', titleIcon: $r('app.media.nav_inbox'), back: true, drawerOpen: $drawerOpen }) {
        if (!this.task) {
          EmptyState({ title: '无法打开此记录', detail: '请从收件箱进入。' })
        } else {
          Column() {
            Row({ space: 8 }) {
              this.kindButton('task', '任务')
              this.kindButton('memo', '备忘')
            }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
            Column() {
              if (this.kind === 'task') {
                TaskEditor({ task: this.task, parents: this.parents })
              } else {
                MemoEditor({ task: this.task })
              }
            }.width('100%').layoutWeight(1)
            Divider().color(UiColor.outline)
            Row({ space: 16 }) {
              Button('删除').layoutWeight(1).height(44).borderRadius(10)
                .backgroundColor(UiColor.container).fontColor(UiColor.error).enabled(false)
              Button(this.kind === 'task' ? '转换为任务' : '转换为备忘').layoutWeight(1).height(44).borderRadius(10)
                .backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary).enabled(false)
            }.width('100%').padding(16)
          }.width('100%').height('100%')
        }
      }
    }.width('100%').height('100%')
  }
}
