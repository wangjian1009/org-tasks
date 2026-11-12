import { display, window } from '@kit.ArkUI'
import { UiColor, UiSize } from '../ui/Theme'
import { PopupMenu, PopupMenuItem } from './PopupMenu'

// 所有短操作菜单共用入口；内容测量与排版统一交给 PopupMenu。
@Component
export struct PopupMenuButton {
  @Prop items: PopupMenuItem[] = []
  @Prop icon: Resource = $r('app.media.ui_more')
  @Prop label: string = ''
  @Prop disabled: boolean = false
  @Prop buttonWidth: number = 48
  @Prop buttonHeight: number = 48
  @Prop iconSize: number = 24
  @State visible: boolean = false
  @State maximumWidth: number = 0
  private anchorId: string = ''
  private openRequest: number = 0
  private alive: boolean = false

  aboutToAppear() { this.anchorId = `popup_menu_${this.getUniqueId()}`; this.alive = true }
  aboutToDisappear() { this.alive = false; this.openRequest++; this.visible = false }

  async toggle(): Promise<void> {
    if (this.visible) { this.visible = false; return }
    if (this.disabled || this.items.length === 0) return
    const request = ++this.openRequest
    const ui = this.getUIContext()
    let availableWidth = 0
    try {
      const currentWindow = await window.getLastWindow(ui.getHostContext()!)
      availableWidth = ui.px2vp(currentWindow.getWindowProperties().windowRect.width) - 32
    } catch (_) {
      try { availableWidth = ui.px2vp(display.getDefaultDisplaySync().width) - 32 }
      catch (_) { return }
    }
    if (!this.alive || request !== this.openRequest || this.disabled) return
    this.maximumWidth = Math.max(0, availableWidth)
    this.visible = this.maximumWidth > UiSize.menuBorder * 2
  }

  activate(item: PopupMenuItem) {
    if (this.disabled || item.disabled) return
    this.visible = false
    item.action()
  }

  restoreFocus() {
    if (!this.alive) return
    try { this.getUIContext().getFocusController().requestFocus(this.anchorId) }
    catch (_) { /* 关闭时触发按钮可能已随路由卸载。 */ }
  }

  @Builder
  menu() {
    Column() {
      PopupMenu({ items: this.items, disabled: this.disabled, maximumWidth: this.maximumWidth - UiSize.menuBorder * 2,
        activate: (item: PopupMenuItem): void => { this.activate(item) } })
    }.backgroundColor(UiColor.menu).borderRadius(UiSize.menuRadius)
      .border({ width: UiSize.menuBorder, color: UiColor.menuOutline }).clip(true)
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      Image(this.icon).width(this.iconSize).height(this.iconSize).accessibilityLevel('no')
    }.id(this.anchorId).width(this.buttonWidth).height(this.buttonHeight).padding(0)
      .backgroundColor(this.visible ? UiColor.menu : Color.Transparent).borderRadius(8)
      .enabled(!this.disabled).accessibilityText(this.label).onClick(() => { this.toggle() })
      .bindPopup(this.visible, { builder: this.menu, placement: Placement.BottomRight,
        targetSpace: 6, enableArrow: false, radius: UiSize.menuRadius, popupColor: UiColor.menu,
        backgroundBlurStyle: BlurStyle.NONE, shadow: { radius: 18, color: '#55000000', offsetY: 6 },
        mask: { color: Color.Transparent }, focusable: true, autoCancel: true,
        onStateChange: (event): void => {
          this.visible = event.isVisible
          if (!event.isVisible) this.restoreFocus()
        } })
  }
}
