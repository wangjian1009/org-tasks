import { CoreTask } from '../../services/NativeCoreService'
import { EmptyState } from '../controls/EmptyState'
import { OrgContentView } from '../OrgContentView'
import { UiColor } from '../../ui/Theme'

// 备忘正文组件；备忘编辑页使用多行文本模式。
@Component
export struct MemoEditor {
  @Prop task: CoreTask | undefined = undefined
  @Prop editable: boolean = false
  @Prop disabled: boolean = false
  @Prop bodyValue: string = ''
  bodyChanged: (value: string) => void = () => {}

  build() {
    if (this.editable) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        TextArea({ text: this.bodyValue, placeholder: '正文' })
          .width('100%').height('100%').fontSize(19).lineHeight(28)
          .fontColor(UiColor.text).placeholderColor(UiColor.secondary)
          .backgroundColor(Color.Transparent).padding({ left: 28, right: 28, top: 20, bottom: 64 })
          .enabled(!this.disabled).onChange((value: string): void => { this.bodyChanged(value) })
        Text(`共 ${this.bodyValue.length} 字`).fontSize(16).fontColor(UiColor.secondary)
          .padding({ right: 28, bottom: 24 })
      }.width('100%').layoutWeight(1).alignContent(Alignment.BottomEnd)
    } else if (!this.task) {
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
