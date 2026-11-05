import { common } from '@kit.AbilityKit'
import { UiColor } from '../ui/Theme'

// 分享扩展只转交标题；所有仓库写入都在统一捕捉窗口执行。
@Entry({ useSharedStorage: true })
@Component
struct ShareCapture {
  @LocalStorageLink('sharedTitle') title: string = ''
  @LocalStorageLink('shareReady') @Watch('forward') ready: boolean = false
  @LocalStorageLink('shareError') error: string = ''
  @State forwarding: boolean = false

  aboutToAppear() { if (this.ready) this.forward() }

  async forward() {
    if (!this.ready || this.forwarding) return
    this.forwarding = true
    const context = getContext(this) as common.UIExtensionContext
    try {
      await context.startAbility({ bundleName: context.applicationInfo.name, abilityName: 'CaptureAbility', parameters: { title: this.title } })
      await context.terminateSelf()
    } catch (e) { this.error = '打开快速捕捉失败，请重试'; this.forwarding = false }
  }

  build() {
    Column({ space: 20 }) {
      Text(this.error || '正在打开快速捕捉…').fontSize(18).fontColor(UiColor.text)
      if (this.error && this.ready) Button('重试').onClick((): void => { this.forward() })
      Button('关闭').backgroundColor(UiColor.selected).fontColor(UiColor.onSelected)
        .onClick((): void => { (getContext(this) as common.UIExtensionContext).terminateSelf() })
    }.width('100%').height('100%').padding(24).justifyContent(FlexAlign.Center).backgroundColor(UiColor.surface)
  }
}
