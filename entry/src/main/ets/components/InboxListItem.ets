import { CoreTask } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'
import { TitleText } from './TitleText'
import { OrgContentView } from './OrgContentView'

// 收件箱记录始终显示标题与正文，不维护任务列表的展开状态。
@Component
export struct InboxListItem {
  @Prop record: CoreTask
  @Prop selected: boolean = false
  open: () => void = () => {}

  build() {
    Column({ space: 8 }) {
      TitleText({ text: this.record.heading, parts: this.record.headingParts, textSize: 18,
        weight: FontWeight.Medium, activate: this.open })
        .width('100%').onClick((): void => { this.open() })
      if (this.record.bodyHtml.trim().length > 0) {
        OrgContentView({ fragment: this.record.bodyHtml, embedded: true,
          contentBackground: this.selected ? '#323D3A' : UiColor.surface, embeddedPadding: 0, activate: this.open }).width('100%').onClick((): void => {})
      }
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
      .backgroundColor(this.selected ? '#323D3A' : UiColor.surface)
      .border({ width: this.selected ? 1.5 : 0, color: UiColor.primary }).borderRadius(14)
      .onClick((): void => { this.open() })
  }
}
