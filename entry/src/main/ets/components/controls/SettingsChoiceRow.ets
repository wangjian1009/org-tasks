import { display, window } from '@kit.ArkUI'
import { UiColor, UiSize } from '../../ui/Theme'
import { PopupMenu, PopupMenuItem } from './PopupMenu'
import { SettingsRow } from './SettingsRow'

// 设置中的少量互斥选项使用同行浮层，复用公共菜单的勾选和测量规则。
@Component
export struct SettingsChoiceRow {
  @Prop title: string = ''
  @Prop value: string = ''
  @Prop icon: Resource | undefined = undefined
  @Prop divider: boolean = true
  @Prop disabled: boolean = false
  @Prop items: PopupMenuItem[] = []
  @State visible: boolean = false
  @State maximumWidth: number = 0
  private alive: boolean = false
  private openRequest: number = 0

  aboutToAppear() { this.alive = true }
  aboutToDisappear() { this.alive = false; this.openRequest++; this.visible = false }

  async toggle(): Promise<void> {
    if (this.visible) { this.visible = false; return }
    if (this.disabled || this.items.length === 0) return
    const request = ++this.openRequest
    const ui = this.getUIContext()
    let width = 0
    try {
      const currentWindow = await window.getLastWindow(ui.getHostContext()!)
      width = ui.px2vp(currentWindow.getWindowProperties().windowRect.width) - 32
    } catch (_) {
      try { width = ui.px2vp(display.getDefaultDisplaySync().width) - 32 }
      catch (_) { return }
    }
    if (!this.alive || request !== this.openRequest || this.disabled) return
    this.maximumWidth = Math.max(0, width - UiSize.menuBorder * 2)
    this.visible = this.maximumWidth > 0
  }

  @Builder
  menu() {
    Column() {
      PopupMenu({ items: this.items, disabled: this.disabled, maximumWidth: this.maximumWidth,
        activate: (item: PopupMenuItem): void => {
          if (this.disabled || item.disabled) return
          this.visible = false
          item.action()
        } })
    }.backgroundColor(UiColor.menu).borderRadius(UiSize.menuRadius)
      .border({ width: UiSize.menuBorder, color: UiColor.menuOutline }).clip(true)
  }

  build() {
    SettingsRow({ title: this.title, value: this.value, icon: this.icon, divider: this.divider,
      disclosureIcon: $r('app.media.ui_down'), disabled: this.disabled, action: (): void => { this.toggle() } })
      .bindPopup(this.visible, { builder: this.menu(), placement: Placement.BottomRight,
        targetSpace: 6, enableArrow: false, radius: UiSize.menuRadius, popupColor: UiColor.menu,
        backgroundBlurStyle: BlurStyle.NONE, shadow: { radius: 18, color: '#55000000', offsetY: 6 },
        mask: { color: Color.Transparent }, focusable: true, autoCancel: true,
        onStateChange: (event): void => { this.visible = event.isVisible } })
  }
}
