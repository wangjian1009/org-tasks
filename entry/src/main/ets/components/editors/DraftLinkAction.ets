import { FrameCallback } from '@ohos.arkui.UIContext'
import { ComponentContent, window } from '@kit.ArkUI'
import { CoreLinkValue, CoreTextLink, formatOrgLink } from '../../services/NativeCoreService'
import { UiColor } from '../../ui/Theme'
import { LinkEditController, LinkView } from '../LinkView'

interface DraftLinkRange {
  start: number
  end: number
}

interface DraftLinkToolbarPosition {
  bottom: number
  open: () => void
}

@Builder
function draftLinkButton(open: () => void, disabled: boolean) {
  Button({ type: ButtonType.Normal }) {
    Row({ space: 6 }) {
      Image($r('app.media.ui_link_other')).width(16).height(16).fillColor(UiColor.primary)
      Text('链接').fontSize(13).fontColor(UiColor.primary)
    }.padding({ left: 10, right: 10 })
  }.height(44).backgroundColor(Color.Transparent).focusable(false).enabled(!disabled)
    .accessibilityText('插入链接').onClick(open)
}

@Builder
function draftLinkKeyboardToolbar(position: DraftLinkToolbarPosition) {
  Stack({ alignContent: Alignment.TopStart }) {
    Row() {
      draftLinkButton(position.open, false)
    }.width('100%').height(44).justifyContent(FlexAlign.End).padding({ right: 12 })
      .backgroundColor(UiColor.surface).position({ left: 0, bottom: position.bottom })
      .onTouch((event: TouchEvent): void => { event.stopPropagation(); LinkEditController.protectInteraction() })
  }.width('100%').height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
}

export class DraftInputFrame extends FrameCallback {
  private update: () => void
  constructor(update: () => void) { super(); this.update = update }
  onFrame(_frameTimeInNano: number): void {}
  onIdle(_timeLeftInNano: number): void { this.update() }
}

export class DraftLinkSelection {
  private range: DraftLinkRange | undefined = undefined
  busy: boolean = false

  update(start: number, end: number): void {
    if (!this.busy) this.range = { start, end }
  }

  reset(): void { this.range = undefined }

  current(length: number): DraftLinkRange {
    return {
      start: Math.min(this.range?.start ?? length, length),
      end: Math.min(this.range?.end ?? length, length)
    }
  }
}

@Component
export struct DraftLinkAction {
  @Prop source: string = ''
  @Prop @Watch('syncToolbar') disabled: boolean = false
  inputId: string = ''
  selection: DraftLinkSelection = new DraftLinkSelection()
  editor: LinkEditController = new LinkEditController()
  write: (source: string) => void = () => {}
  select: (start: number, end: number) => void = () => {}
  @State private title: string | undefined = undefined
  @State private keyboardToolbar: boolean = false
  private original: string = ''
  private range: DraftLinkRange = { start: 0, end: 0 }
  private active: boolean = false
  private generation: number = 0
  private hostWindow: window.Window | undefined = undefined
  private keyboardHeight: number = 0
  private toolbarContent: ComponentContent<DraftLinkToolbarPosition> | undefined = undefined
  private onKeyboardHeight = (height: number): void => {
    this.keyboardHeight = height
    this.syncToolbar()
  }

  aboutToAppear(): void {
    this.active = true
    try {
      const name = this.getUIContext().getWindowName()
      if (!name) return
      this.hostWindow = window.findWindow(name)
      this.hostWindow.on('keyboardHeightChange', this.onKeyboardHeight)
      this.keyboardHeight = this.hostWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD).bottomRect.height
      this.syncToolbar()
    } catch (_) {
      // 窗口还未就绪时，输入框保留自己的链接按钮。
    }
  }

  aboutToDisappear(): void {
    this.active = false
    this.hostWindow?.off('keyboardHeightChange', this.onKeyboardHeight)
    this.syncToolbar()
    this.generation++
    this.selection.busy = false
  }

  syncToolbar(): void {
    const context = this.getUIContext()
    const overlay = context.getOverlayManager()
    if (!this.active || this.disabled || this.selection.busy || !this.keyboardHeight) {
      if (this.toolbarContent) {
        overlay.removeComponentContent(this.toolbarContent)
        this.toolbarContent.dispose()
        this.toolbarContent = undefined
        this.keyboardToolbar = false
      }
      return
    }
    let bottom = this.keyboardHeight
    try {
      const systemBottom = this.hostWindow?.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).bottomRect.height ?? 0
      const navigationBottom = this.hostWindow?.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR)
        .bottomRect.height ?? 0
      bottom = Math.max(0, bottom - Math.max(systemBottom, navigationBottom))
    } catch (_) {
      // 窗口切换期间仍可按键盘高度定位。
    }
    const position: DraftLinkToolbarPosition = { bottom: context.px2vp(bottom), open: (): void => { this.open() } }
    if (this.toolbarContent) {
      this.toolbarContent.update(position)
      return
    }
    this.toolbarContent = new ComponentContent(context, wrapBuilder(draftLinkKeyboardToolbar), position)
    overlay.addComponentContent(this.toolbarContent)
    this.keyboardToolbar = true
  }

  private open(): void {
    if (this.disabled || this.selection.busy) return
    this.generation++
    this.original = this.source
    this.range = this.selection.current(this.source.length)
    this.selection.busy = true
    this.title = this.original.slice(this.range.start, this.range.end).replace(/\r\n|[\r\n]/g, ' ')
    this.syncToolbar()
  }

  private async insert(value: CoreLinkValue | null): Promise<void> {
    if (!value) return
    const link = await formatOrgLink(value)
    if (!this.active || this.title === undefined || this.disabled || this.source !== this.original) {
      throw new Error('文字草稿已变化，请取消后重试')
    }
    const start = this.range.start
    this.write(this.original.slice(0, start) + link + this.original.slice(this.range.end))
    const caret = start + link.length
    this.range = { start: caret, end: caret }
  }

  private close(): void {
    if (!this.active || this.title === undefined) return
    this.title = undefined
    const generation = this.generation
    const range = this.range
    const context = this.getUIContext()
    context.postFrameCallback(new DraftInputFrame((): void => {
      if (!this.active || generation !== this.generation) return
      try {
        context.getFocusController().requestFocus(this.inputId)
        this.select(range.start, range.end)
      } catch (_) {
        // 页面切换时输入框可能已离开视口。
      } finally {
        this.selection.busy = false
        this.selection.update(range.start, range.end)
        this.syncToolbar()
      }
    }))
  }

  build() {
    Column() {
      LinkView({ editor: this.editor, editable: !this.disabled, insertionTitle: this.title,
        change: (_link: CoreTextLink, value: CoreLinkValue | null): Promise<void> => this.insert(value),
        editingChanged: (editing: boolean): void => { if (!editing) this.close() } }).width('100%')
      if (this.title === undefined && !this.keyboardToolbar) {
        Row() {
          draftLinkButton(() => this.open(), this.disabled)
        }.width('100%').justifyContent(FlexAlign.End)
      }
    }.width('100%')
      .onTouch((event: TouchEvent): void => { event.stopPropagation(); LinkEditController.protectInteraction() })
      .onClick((): void => { LinkEditController.protectInteraction() })
  }
}
