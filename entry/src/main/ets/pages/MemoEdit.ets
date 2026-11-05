import { router } from '@kit.ArkUI'
import { CoreTask } from '../services/NativeCoreService'
import { AppShell } from '../components/AppShell'
import { MemoEditor } from '../components/MemoEditor'

interface MemoParams { task?: CoreTask }

@Entry
@Component
struct MemoEdit {
  @State memo: CoreTask | undefined = undefined
  @State drawerOpen: boolean = false

  aboutToAppear() {
    const params = router.getParams() as MemoParams | undefined
    this.memo = params?.task
  }

  build() {
    Column() {
      AppShell({ title: '备忘编辑', titleIcon: $r('app.media.nav_memo'), back: true, drawerOpen: $drawerOpen }) {
        MemoEditor({ task: this.memo })
      }
    }.width('100%').height('100%')
  }
}
