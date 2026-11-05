import { CoreTask } from '../services/NativeCoreService'
import { EmptyState } from './Controls'
import { OrgContentView } from './OrgContentView'
import { UiColor } from '../ui/Theme'

// 备忘仅保留正文；规划页与独立编辑页使用同一内容组件。
@Component
export struct MemoEditor {
  @Prop task: CoreTask | undefined = undefined

  build() {
    if (!this.task) {
      EmptyState({ title: '无法打开此备忘', detail: '请从备忘列表进入。' })
    } else {
      Scroll() {
        Column() {
          if (this.task!.bodyHtml) {
            OrgContentView({ fragment: this.task!.bodyHtml, embedded: true }).width('100%')
          } else {
            Text('没有正文内容').width('100%').fontSize(16).fontColor(UiColor.secondary)
              .padding({ left: 16, right: 16, top: 20, bottom: 24 })
          }
        }.width('100%').padding({ bottom: 24 })
      }.width('100%').height('100%').align(Alignment.TopStart)
    }
  }
}
