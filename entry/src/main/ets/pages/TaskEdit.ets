import { router } from '@kit.ArkUI'
import { CoreTask } from '../services/NativeCoreService'
import { AppShell } from '../components/AppShell'
import { TaskEditor } from '../components/TaskEditor'

interface TaskParams { task?: CoreTask; parents?: string[] }

@Entry
@Component
struct TaskEdit {
  @State task: CoreTask | undefined = undefined
  @State parents: string[] = []
  @State drawerOpen: boolean = false

  aboutToAppear() {
    const params = router.getParams() as TaskParams | undefined
    this.task = params?.task
    this.parents = params?.parents || []
  }

  build() {
    Column() {
      AppShell({ title: '任务编辑', titleIcon: $r('app.media.ui_edit'), back: true, drawerOpen: $drawerOpen }) {
        TaskEditor({ task: this.task, parents: this.parents })
      }
    }.width('100%').height('100%')
  }
}
