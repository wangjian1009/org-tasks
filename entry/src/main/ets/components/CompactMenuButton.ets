import { display, window } from '@kit.ArkUI'
import { UiColor, UiSize } from '../ui/Theme'

export interface CompactMenuItem {
  title: string
  icon?: Resource
  checked?: boolean
  dangerous?: boolean
  action: () => void
}

// 操作菜单按文字测量，原生 Popup 负责避让、遮罩与返回关闭。
@Component
export struct CompactMenuButton {
  @Prop items: CompactMenuItem[] = []
  @Prop icon: Resource = $r('app.media.ui_more')
  @Prop label: string = ''
  @Prop disabled: boolean = false
  @Prop buttonWidth: number = 48
  @Prop buttonHeight: number = 48
  @Prop iconSize: number = 24
  @State visible: boolean = false
  @State menuWidth: number = 0
  private anchorId: string = `compact_menu_${this.getUniqueId()}`
  private openRequest: number = 0
  private alive: boolean = false

  aboutToAppear() { this.alive = true }
  aboutToDisappear() { this.alive = false; this.openRequest++; this.visible = false }

  hasIcons(): boolean { return this.items.some(item => item.icon !== undefined) }
  hasSelection(): boolean { return this.items.some(item => item.checked !== undefined) }

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
    let textWidth = 0
    this.items.forEach(item => {
      const size = ui.getMeasureUtils().measureTextSize({ textContent: item.title, fontSize: `${UiSize.menuFont}fp` })
      textWidth = Math.max(textWidth, ui.px2vp(Number(size.width)))
    })
    const adornments = (this.hasIcons() ? UiSize.menuIcon + UiSize.menuGap : 0) +
      (this.hasSelection() ? UiSize.menuIcon + UiSize.menuGap : 0)
    this.menuWidth = Math.min(Math.max(0, availableWidth), Math.ceil(textWidth + UiSize.menuPadding * 2 + adornments))
    this.visible = this.menuWidth > 0
  }

  activate(item: CompactMenuItem) {
    if (this.disabled) return
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
      ForEach(this.items, (item: CompactMenuItem, index: number) => {
        Button({ type: ButtonType.Normal }) {
          Row({ space: UiSize.menuGap }) {
            if (this.hasIcons()) {
              if (item.icon) { Image(item.icon).width(UiSize.menuIcon).height(UiSize.menuIcon).accessibilityLevel('no') }
              else { Blank().width(UiSize.menuIcon) }
            }
            Text(item.title).fontSize(UiSize.menuFont).fontColor(item.dangerous ? UiColor.error : UiColor.text)
              .layoutWeight(1).wordBreak(WordBreak.BREAK_WORD)
            if (this.hasSelection()) {
              if (item.checked) { Image($r('app.media.ui_done')).width(UiSize.menuIcon).height(UiSize.menuIcon).accessibilityLevel('no') }
              else { Blank().width(UiSize.menuIcon) }
            }
          }.width('100%').constraintSize({ minHeight: UiSize.menuRow })
            .padding({ left: UiSize.menuPadding, right: UiSize.menuPadding, top: 10, bottom: 10 })
        }.width('100%').padding(0).backgroundColor(Color.Transparent).borderRadius(UiSize.menuRadius)
          .enabled(!this.disabled).defaultFocus(index === 0)
          .accessibilityText(`${item.title}${item.checked === undefined ? '' : item.checked ? '，已选中' : '，未选中'}`)
          .onClick(() => { this.activate(item) })
      }, (item: CompactMenuItem) => item.title)
    }.width(this.menuWidth).backgroundColor(UiColor.menu).borderRadius(UiSize.menuRadius)
      .border({ width: 0.5, color: UiColor.menuOutline }).clip(true)
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      Image(this.icon).width(this.iconSize).height(this.iconSize).accessibilityLevel('no')
    }.id(this.anchorId).width(this.buttonWidth).height(this.buttonHeight).padding(0)
      .backgroundColor(this.visible ? UiColor.menu : Color.Transparent).borderRadius(8)
      .enabled(!this.disabled).accessibilityText(this.label).onClick(() => { this.toggle() })
      .bindPopup(this.visible, { builder: this.menu, width: this.menuWidth, placement: Placement.BottomRight,
        targetSpace: 6, enableArrow: false, radius: UiSize.menuRadius, popupColor: UiColor.menu,
        backgroundBlurStyle: BlurStyle.NONE, shadow: { radius: 18, color: '#55000000', offsetY: 6 },
        mask: { color: Color.Transparent }, focusable: true, autoCancel: true,
        onStateChange: (event): void => {
          this.visible = event.isVisible
          if (!event.isVisible) this.restoreFocus()
        } })
  }
}
