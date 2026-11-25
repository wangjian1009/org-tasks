import { localizedText } from '../ui/LocalizedText'
import { pasteboard } from '@kit.BasicServicesKit'
import { display } from '@kit.ArkUI'
import { PopupMenu, PopupMenuItem } from './controls/PopupMenu'
import { InternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { LINK_PROTOCOLS, LinkProtocolChoice, linkProtocol, switchLinkProtocol, internalLinkTarget } from '../ui/LinkPresentation'
import { common, Want } from '@kit.AbilityKit'
import { petalMaps } from '@kit.MapKit'
import { webview } from '@kit.ArkWeb'
import { FrameCallback } from '@ohos.arkui.UIContext'
import { TaskInlineFocus } from '../ui/TaskInlineFocus'
import { CoreTitlePart, CoreTextLink, CoreLinkValue } from '../services/NativeCoreService'
import { UiColor, UiSize } from '../ui/Theme'
import { titleCountInline } from './TitleCountInline'
import { titleCounts } from '../ui/TitleCountPresentation'
import { CoreTitleCount } from '../services/NativeCoreService'
import { PageNavigator } from '../services/PageNavigator'
import { AppLinkManager, appLinkName, openAppLink } from '../services/AppLinkService'

interface MapAppChoice {
  title: string
  icon: Resource
  contextLabel: string
  description: string
  supported: boolean
  select: () => Promise<void>
}

interface DocumentLinkProtocol { kind: string; title: string; prefix: string; path: string }
interface LinkProtocolHit { title: string; url: string; x: number; y: number; width: number; height: number }

class LinkFocusFrame extends FrameCallback {
  private callback: () => void
  constructor(callback: () => void) { super(); this.callback = callback }
  onFrame(_frameTimeInNano: number): void {}
  onIdle(_timeLeftInNano: number): void { this.callback() }
}

interface LinkHit {
  link: CoreTextLink | null
  href: string
  label: string
  x: number
  y: number
  width: number
  menu?: boolean
  url?: string
}

// 同一任务中的标题和备注共享结束输入入口，保存失败时阻止收起及其他字段操作。
export class LinkEditController {
  private static protectedUntil: number = 0
  static protectInteraction() { LinkEditController.protectedUntil = Date.now() + 100 }
  static interactionProtected(): boolean { return Date.now() < LinkEditController.protectedUntil }
  private owners: Map<number, () => Promise<boolean>> = new Map()
  bind(owner: number, finish: () => Promise<boolean>) { this.owners.set(owner, finish) }
  release(owner: number) { this.owners.delete(owner) }
  async finish(except: number = -1): Promise<boolean> {
    for (const entry of this.owners.entries()) if (entry[0] !== except && !await entry[1]()) return false
    return true
  }
}

// Web 适配器只转交导航事件；协议、地图选择与失败反馈均由控件拥有。
export class LinkController {
  private activate: (href: string) => Promise<void>
  constructor(activate: (href: string) => Promise<void>) { this.activate = activate }
  hit: (payload: string) => void = () => {}
  protocol: (payload: string) => void = () => {}
  draft: (title: string, url: string) => void = () => {}
  save: (title: string, url: string) => void = () => {}
  cancel: () => void = () => {}
  ready: () => void = () => {}

  open(href: string): Promise<void> { return this.activate(href) }

  navigate(href: string, mainFrame: boolean): boolean {
    if (href === 'about:blank' || href.startsWith('data:') || href.startsWith('#')) return false
    if (mainFrame) this.open(href)
    return true
  }
}

@Component
export struct LinkView {
  @Prop text: string = ''
  @Prop parts: CoreTitlePart[] = []
  @Prop textSize: number = UiSize.taskFont
  @Prop weight: FontWeight = FontWeight.Normal
  @Prop showCounts: boolean = false
  @Prop lineLimit: number = 0
  @Prop lineHeight: number | undefined = undefined
  @Prop cancelled: boolean = false
  @Prop @Watch('insertionChanged') insertionTitle: string | undefined = undefined
  @Prop copyable: boolean = false
  @Prop openLinks: boolean = true
  @Prop editable: boolean = false
  @Prop revision: string = ''
  @Prop document: boolean = false
  @Prop contentHeight: number | string = '100%'
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  activate: (() => void) | undefined = undefined
  change: ((link: CoreTextLink, value: CoreLinkValue | null) => Promise<void>) | undefined = undefined
  editingChanged: (editing: boolean) => void = () => {}
  editor: LinkEditController = new LinkEditController()
  webController: webview.WebviewController | undefined = undefined
  remeasure: () => void = () => {}
  @BuilderParam content: (links: LinkController) => void = this.emptyContent
  @State protocolVisible: boolean = false
  @State protocolHeight: number = 320
  @State protocolX: number = 0
  @State protocolY: number = 0
  @State menuWidth: number = 320
  private textController: TextController = new TextController()
  private suppressClickUntil: number = 0
  @State chooserVisible: boolean = false
  @State mapChoices: MapAppChoice[] = []
  @State launching: boolean = false
  @State editing: boolean = false
  @State menuVisible: boolean = false
  @State selected: LinkHit | undefined = undefined
  @State titleDraft: string = ''
  @State urlDraft: string = ''
  @State saving: boolean = false
  @State editError: string = ''
  private owner: number = 0
  private widthVp: number = 1
  private selectedRevision: string = ''
  private active: boolean = false
  private generation: number = 0
  private inputFocus: TaskInlineFocus = new TaskInlineFocus(
    (callback: () => void) => { this.getUIContext().postFrameCallback(new LinkFocusFrame(callback)) },
    (key: string) => { this.getUIContext().getFocusController().requestFocus(key) })
  private links: LinkController = new LinkController((href: string): Promise<void> => this.navigate(href))

  aboutToAppear() {
    this.active = true; this.generation++; this.launching = false
    this.owner = this.getUniqueId()
    this.editor.bind(this.owner, async (): Promise<boolean> => {
      if (this.insertionTitle !== undefined) return false
      return !this.editing || await this.saveEdit()
    })
    this.links.hit = (payload: string): void => { this.webHit(payload) }
    this.links.protocol = (payload: string): void => { this.webProtocol(payload) }
    this.links.draft = (title: string, url: string): void => { if (this.editing && !this.saving) { this.titleDraft = title; this.urlDraft = url } }
    this.links.save = (title: string, url: string): void => {
      if (!this.editing || this.saving) return
      this.titleDraft = title; this.urlDraft = url; this.saveEdit()
    }
    this.links.cancel = (): void => { this.cancelEdit() }
    this.links.ready = (): void => { this.installDocument() }
  }
  aboutToDisappear() {
    this.inputFocus.cancel()
    this.active = false; this.generation++; this.chooserVisible = false; this.mapChoices = []; this.menuVisible = false; this.protocolVisible = false
    this.editor.release(this.owner)
    if (this.editing) this.editingChanged(false)
  }

  async navigate(href: string): Promise<void> {
    await this.open(href)
  }

  async select(hit: LinkHit): Promise<void> {
    if (!this.active || this.saving || this.editing) return
    this.selected = hit; this.selectedRevision = this.revision; this.editError = ''
    if (hit.menu) {
      try { this.menuWidth = this.getUIContext().px2vp(display.getDefaultDisplaySync().width) - 32 } catch (_) {}
      this.menuVisible = true
    } else if (hit.href) { await this.open(hit.href) }
    else { this.notify(localizedText($r('app.string.text_this_link_is_not_supported_for_opening'))) }
  }

  selectPart(part: CoreTitlePart, event: ClickEvent) {
    LinkEditController.protectInteraction()
    if (Date.now() < this.suppressClickUntil) return
    this.suppressClickUntil = Date.now() + 100
    this.select({ link: part.link, href: part.href || '', label: part.text, x: event.x, y: event.y, width: this.widthVp })
  }

  webHit(payload: string) {
    if (!this.active) return
    try {
      const hit = JSON.parse(payload) as LinkHit
      this.select(hit)
    } catch (_) { this.notify(localizedText($r('app.string.text_couldn_t_read_the_link_reload_the'))) }
  }

  async installDocument() {
    if (!this.active || !this.webController) return
    const generation = this.generation
    try {
      await this.webController.runJavaScript(linkDocumentScript())
      if (this.active && generation === this.generation) this.remeasure()
    }
    catch (_) { this.notify(localizedText($r('app.string.text_link_control_has_failed_to_load_please'))) }
  }

  insertionChanged(): void {
    const title = this.insertionTitle
    if (title === undefined || !this.active) return
    const link: CoreTextLink = { start: 0, end: 0, source: '', title, url: '' }
    this.selected = { link, href: '', label: link.title, x: 0, y: 0, width: this.widthVp }
    this.selectedRevision = this.revision
    this.showEditor(link)
  }

  async beginEdit() {
    if (!this.active || !this.editable || !this.selected?.link || this.saving || this.editing) return
    const generation = this.generation
    const selected = this.selected
    if (!await this.editor.finish(this.owner) || !this.active || !this.editable || generation !== this.generation
      || selected !== this.selected || this.revision !== this.selectedRevision || this.editing) return
    this.showEditor(selected.link!)
  }

  private showEditor(link: CoreTextLink): void {
    const generation = this.generation
    this.menuVisible = false
    this.titleDraft = link.title; this.urlDraft = link.url
    this.editError = ''; this.editing = true; this.editingChanged(true)
    if (!this.document) this.inputFocus.request(this.insertionTitle === undefined ?
      `link_title_${this.owner}` : `link_url_${this.owner}`)
    if (this.document && this.webController) {
      this.webController.runJavaScript(`window.orgLinkEdit?.(${JSON.stringify(link)}, ${JSON.stringify(this.titleDraft)}, ${JSON.stringify(this.urlDraft)})`)
        .then((): void => { if (this.active && generation === this.generation) this.remeasure() })
        .catch((): void => { if (this.active && generation === this.generation) this.editError = localizedText($r('app.string.text_couldn_t_open_the_link_editor_try')) })
    }
  }

  cancelEdit() {
    if (this.saving) return
    this.inputFocus.cancel()
    this.protocolVisible = false; this.menuVisible = false; this.editing = false; this.editError = ''; this.editingChanged(false)
    if (this.webController) this.webController.runJavaScript('window.orgLinkCancel?.()').then((): void => { this.remeasure() }).catch(() => {})
  }

  async commit(value: CoreLinkValue | null): Promise<boolean> {
    if (!this.active || !this.selected?.link || this.saving) return false
    const generation = this.generation
    const selected = this.selected
    if (!value && !await this.editor.finish(this.owner)) return false
    if (!this.active || generation !== this.generation || selected !== this.selected) return false
    if (!this.editable || !this.change) { this.editError = localizedText($r('app.string.text_the_current_link_cannot_be_modified_please')); this.notify(this.editError); this.documentStatus(this.editError, false); return false }
    if (this.revision !== this.selectedRevision) { this.editError = localizedText($r('app.string.text_changed_content_please_cancel_editing_and_reload')); this.notify(this.editError); this.documentStatus(this.editError, false); return false }
    if (value && !value.url.trim()) { this.editError = localizedText($r('app.string.text_link_cannot_be_empty')); this.notify(this.editError); this.documentStatus(this.editError, false); return false }
    this.saving = true; this.menuVisible = false; this.editError = ''
    this.documentStatus('', true)
    try {
      await this.change(this.selected.link, value)
      if (!this.active || generation !== this.generation) return true
      this.saving = false; this.cancelEdit()
      return true
    } catch (error) {
      if (this.active && generation === this.generation) {
        this.editError = (error as Error).message || localizedText($r('app.string.text_save_link_failed_please_try_again'))
        this.notify(this.editError)
        this.documentStatus(this.editError, false)
      }
      return false
    } finally { if (this.active && generation === this.generation) this.saving = false }
  }

  documentStatus(message: string, busy: boolean) {
    if (this.webController) this.webController.runJavaScript(`window.orgLinkStatus?.(${JSON.stringify(message)}, ${busy})`).catch(() => {})
  }

  async saveEdit(): Promise<boolean> {
    if (!this.editing) return true
    if (this.insertionTitle === undefined && this.selected?.link &&
      this.titleDraft === this.selected.link.title && this.urlDraft === this.selected.link.url) {
      this.cancelEdit(); return true
    }
    return await this.commit({ title: this.titleDraft, url: this.urlDraft })
  }

  async copySelected(title: boolean): Promise<void> {
    if (!this.selected) return
    this.menuVisible = false
    const value = title ? this.selected.label : this.selected.link?.url || this.selected.url || this.selected.href
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value))
      this.notify(title ? localizedText($r('app.string.text_title_copied')) : localizedText($r('app.string.text_link_copied')))
    } catch (_) { this.notify(localizedText($r('app.string.text_copy_failed_try_again'))) }
  }

  menuItems(): PopupMenuItem[] {
    const items: PopupMenuItem[] = [
      { title: localizedText($r('app.string.text_copy_link')), icon: $r('app.media.ui_link_copy'), action: (): void => { this.copySelected(false) } },
      { title: localizedText($r('app.string.text_copy_title')), icon: $r('app.media.ui_link_copy'), action: (): void => { this.copySelected(true) } }
    ]
    if (this.editable && this.selected?.link && this.change) {
      items.push({ title: localizedText($r('app.string.text_edit')), icon: $r('app.media.ui_link_edit'), action: (): void => { this.beginEdit() } })
      items.push({ title: localizedText($r('app.string.text_delete')), icon: $r('app.media.ui_delete'), dangerous: true, action: (): void => { this.commit(null) } })
    }
    return items
  }

  @Builder
  linkMenu() {
    Column() {
      PopupMenu({ items: this.menuItems(), disabled: this.saving, maximumWidth: this.menuWidth,
        activate: (item: PopupMenuItem): void => { this.menuVisible = false; item.action() } })
    }.backgroundColor(UiColor.menu).borderRadius(UiSize.menuRadius)
      .border({ width: UiSize.menuBorder, color: UiColor.menuOutline }).clip(true)
  }

  changeProtocol(kind: string) {
    if (!this.active || !this.editable || !this.editing || this.saving) return
    this.urlDraft = switchLinkProtocol(this.urlDraft, kind)
    this.protocolVisible = false
    if (this.document && this.webController) {
      const generation = this.generation
      this.webController.runJavaScript(`window.orgLinkProtocol?.(${JSON.stringify(this.urlDraft)})`)
        .catch((): void => { if (this.active && generation === this.generation) this.notify(localizedText($r('app.string.text_couldn_t_change_the_link_type_try'))) })
    }
  }

  webProtocol(payload: string) {
    if (!this.active || !this.document || !this.editable || !this.editing || this.saving) return
    try {
      const hit = JSON.parse(payload) as LinkProtocolHit
      if (typeof hit.title !== 'string' || typeof hit.url !== 'string' || !Number.isFinite(hit.x)
        || !Number.isFinite(hit.y) || !Number.isFinite(hit.width) || hit.width <= 0 || !Number.isFinite(hit.height) || hit.height <= 0) return
      this.titleDraft = hit.title; this.urlDraft = hit.url
      const scale = this.widthVp / hit.width
      this.protocolX = Math.max(0, Math.min(this.widthVp - 1, hit.x * scale))
      this.protocolY = Math.max(0, hit.y * scale)
      this.protocolHeight = Math.max(88, Math.min(320, hit.height * scale - 32))
      this.openProtocolMenu()
    } catch (_) { this.notify(localizedText($r('app.string.text_couldn_t_open_the_link_type_menu'))) }
  }

  openProtocolMenu() {
    if (!this.active || !this.editable || !this.editing || this.saving) return
    LinkEditController.protectInteraction()
    try { this.menuWidth = this.getUIContext().px2vp(display.getDefaultDisplaySync().width) - 32 } catch (_) {}
    this.protocolVisible = !this.protocolVisible
  }

  protocolState(visible: boolean) {
    this.protocolVisible = visible && this.active && this.editable && this.editing && !this.saving
    if (this.active && this.document && this.webController) {
      this.webController.runJavaScript(`window.orgLinkProtocolState?.(${this.protocolVisible})`).catch(() => {})
    }
  }

  protocolItems(): PopupMenuItem[] {
    return LINK_PROTOCOLS.map((choice: LinkProtocolChoice): PopupMenuItem => ({
      title: localizedText(choice.title), icon: choice.icon, checked: linkProtocol(this.urlDraft).kind === choice.kind,
      action: (): void => { this.changeProtocol(choice.kind) }
    }))
  }

  @Builder
  protocolChoices() {
    Scroll() {
      Column() {
        PopupMenu({ items: this.protocolItems(), maximumWidth: this.menuWidth, disabled: this.saving,
          activate: (item: PopupMenuItem): void => { item.action() } })
      }
    }.constraintSize({ maxHeight: this.protocolHeight, maxWidth: this.menuWidth })
      .nestedScroll({ scrollForward: NestedScrollMode.SELF_ONLY, scrollBackward: NestedScrollMode.SELF_ONLY })
      .edgeEffect(EdgeEffect.None).scrollBar(BarState.Auto)
      .backgroundColor(UiColor.menu).borderRadius(UiSize.menuRadius)
      .border({ width: UiSize.menuBorder, color: UiColor.menuOutline }).clip(true)
  }

  @Builder
  protocolAnchor() {
    Row().width(1).height(1).position({ x: this.protocolX, y: this.protocolY })
      .bindPopup(this.protocolVisible, { builder: this.protocolChoices(), placement: Placement.BottomLeft,
        targetSpace: 6, enableArrow: false, popupColor: UiColor.menu, backgroundBlurStyle: BlurStyle.NONE,
        mask: { color: Color.Transparent }, focusable: true, autoCancel: true,
        onStateChange: (event): void => { this.protocolState(event.isVisible) } })
  }

  @Builder
  menuAnchor() {
    Row().width(1).height(1).position({ x: Math.max(0, Math.min(this.widthVp - 1, (this.selected?.x || 0) * this.widthVp / (this.selected?.width || this.widthVp))),
      y: Math.max(0, (this.selected?.y || 0) * this.widthVp / (this.selected?.width || this.widthVp)) })
      .bindPopup(this.menuVisible, { builder: this.linkMenu(), placement: Placement.Top,
        targetSpace: 6, enableArrow: true, popupColor: UiColor.menu, backgroundBlurStyle: BlurStyle.NONE,
        mask: { color: Color.Transparent }, focusable: false, autoCancel: true,
        onStateChange: (event): void => { this.menuVisible = event.isVisible } })
  }

  @Builder
  linkFormActions() {
    Row({ space: 8 }) {
      Button($r('app.string.text_cancel')).height(40).fontSize(14).fontColor(UiColor.text).backgroundColor(UiColor.field)
        .enabled(!this.saving).onClick((): void => { this.cancelEdit() })
      Button(this.insertionTitle === undefined ? localizedText($r('app.string.text_save')) : localizedText($r('app.string.text_insert'))).height(40).fontSize(14)
        .fontColor(this.insertionTitle === undefined ? UiColor.text : UiColor.onPrimary)
        .backgroundColor(this.insertionTitle === undefined ? UiColor.field : UiColor.primary)
        .enabled(!this.saving).onClick((): void => { this.saveEdit() })
    }.justifyContent(FlexAlign.End)
  }

  @Builder
  linkEditor() {
    Column({ space: 8 }) {
      if (this.insertionTitle === undefined) {
        Text($r('app.string.text_title')).fontSize(12).fontColor(UiColor.secondary).width('100%')
      } else {
        Row({ space: 8 }) {
          Text($r('app.string.text_show_text')).fontSize(12).fontColor(UiColor.secondary).layoutWeight(1)
          this.linkFormActions()
        }.width('100%')
      }
      TextInput({ text: this.titleDraft, placeholder: localizedText($r('app.string.text_show_link_address_untitled')) }).fontSize(14).fontColor(UiColor.text)
        .id(`link_title_${this.owner}`).accessibilityText(this.insertionTitle === undefined ? $r('app.string.link_editor_link_title') : $r('app.string.link_editor_display_text'))
        .enterKeyType(EnterKeyType.Next)
        .onSubmit((_key: EnterKeyType, event: SubmitEvent): void => {
          event.keepEditableState()
          this.inputFocus.request(`link_url_${this.owner}`)
        })
        .onAppear((): void => { this.inputFocus.appeared(`link_title_${this.owner}`) })
        .onDisAppear((): void => { this.inputFocus.disappeared(`link_title_${this.owner}`) })
        .onVisibleAreaChange([0, 1], (visible: boolean): void => { if (visible) this.inputFocus.visible(`link_title_${this.owner}`) })
        .backgroundColor(UiColor.field).enabled(!this.saving).onChange((value: string): void => { this.titleDraft = value })
      Text(this.insertionTitle === undefined ? localizedText($r('app.string.text_link')) : localizedText($r('app.string.text_link_url'))).fontSize(12).fontColor(UiColor.secondary).width('100%')
      Row({ space: 8 }) {
        Button({ type: ButtonType.Normal }) {
          Row() {
            Image(linkProtocol(this.urlDraft).icon).width(16).height(16).fillColor(UiColor.primary)
          }.width(32).height(32).justifyContent(FlexAlign.Center).borderRadius(6).backgroundColor(UiColor.field)
        }.width(44).height(44).padding(0).backgroundColor(Color.Transparent)
          .enabled(!this.saving).accessibilityText(localizedText($r('app.string.text_select_link_protocol_currently'), String(linkProtocol(this.urlDraft).title)))
          .onClick((event: ClickEvent): void => { this.protocolHeight = 320; this.openProtocolMenu() })
          .bindPopup(this.protocolVisible, { builder: this.protocolChoices(), placement: Placement.Bottom,
            targetSpace: 6, enableArrow: false, popupColor: UiColor.menu, backgroundBlurStyle: BlurStyle.NONE,
            mask: { color: Color.Transparent }, focusable: true, autoCancel: true,
            onStateChange: (event): void => { this.protocolState(event.isVisible) } })
        TextInput({ text: this.urlDraft, placeholder: localizedText($r('app.string.text_link_url')) }).fontSize(14).fontColor(UiColor.text).layoutWeight(1)
          .id(`link_url_${this.owner}`).accessibilityText($r('app.string.link_editor_url_placeholder')).enterKeyType(EnterKeyType.Done)
          .onSubmit((_key: EnterKeyType, event: SubmitEvent): void => { event.keepEditableState(); this.saveEdit() })
          .onAppear((): void => { this.inputFocus.appeared(`link_url_${this.owner}`) })
          .onDisAppear((): void => { this.inputFocus.disappeared(`link_url_${this.owner}`) })
          .onVisibleAreaChange([0, 1], (visible: boolean): void => { if (visible) this.inputFocus.visible(`link_url_${this.owner}`) })
          .backgroundColor(UiColor.field).enabled(!this.saving).onChange((value: string): void => { this.urlDraft = value })
      }.width('100%')
      if (this.editError) { Text(this.editError).fontSize(12).fontColor(UiColor.error).width('100%') }
      if (this.insertionTitle === undefined) {
        Row() { this.linkFormActions() }.justifyContent(FlexAlign.End).width('100%')
      }
    }.width('100%').padding(12).borderRadius(10).backgroundColor(UiColor.surface)
      .onTouch((event: TouchEvent): void => { event.stopPropagation(); LinkEditController.protectInteraction() })
      .onClick((): void => { LinkEditController.protectInteraction() })
  }

  async open(href: string): Promise<void> {
    if (!this.active || !this.openLinks || this.launching) return
    const generation = this.generation
    this.launching = true
    try {
      const target = internalLinkTarget(href)
      if (target !== undefined) {
        const processor = this.internalLinkProcessor
        if (!processor) { this.notify(localizedText($r('app.string.text_this_view_cannot_open_links_within_the'))); return }
        const valid = await processor.isValid(target)
        if (!this.active || generation !== this.generation || processor !== this.internalLinkProcessor) return
        if (!valid) { this.notify(localizedText($r('app.string.text_internal_link_target_does_not_exist_or'))); return }
        await processor.process(target)
        return
      }
      const context = this.getUIContext().getHostContext()! as common.UIAbilityContext
      if (href.toLowerCase().startsWith('app:')) {
        await this.activateAppLink(context, href, generation)
        return
      }
      await openExternalLink(context, href, (choices: MapAppChoice[]): void => {
        if (this.active && generation === this.generation) { this.mapChoices = choices; this.chooserVisible = true }
      })
    } catch (_) {
      if (generation === this.generation) this.notify(internalLinkTarget(href) !== undefined
        ? localizedText($r('app.string.text_internal_link_jump_failed_please_confirm_that')) : localizedText($r('app.string.text_couldn_t_open_the_link_check_the')))
    } finally {
      if (this.active && generation === this.generation) this.launching = false
    }
  }

  notify(message: string): void {
    if (!this.active) return
    try { this.getUIContext().getPromptAction().showToast({ message }) }
    catch (_) { console.error('显示链接错误提示失败') }
  }

  async selectMapApp(choice: MapAppChoice): Promise<void> {
    if (!this.active || this.launching) return
    const generation = this.generation
    if (!choice.supported) {
      this.notify(localizedText($r('app.string.text_the_gothic_map_does_not_support_an')))
      return
    }
    this.launching = true
    try {
      await choice.select()
      if (this.active && generation === this.generation) this.chooserVisible = false
    } catch (_) {
      if (generation === this.generation) this.notify(localizedText($r('app.string.text_could_not_open_the_map_please_confirm')))
    } finally {
      if (this.active && generation === this.generation) this.launching = false
    }
  }

  private async activateAppLink(context: common.UIAbilityContext, href: string, generation: number): Promise<void> {
    const name = appLinkName(href)
    if (!name) { this.notify(localizedText($r('app.string.text_the_application_link_is_missing_the_application'))); return }
    const association = await AppLinkManager.shared.find(context, name)
    if (!this.active || generation !== this.generation) return
    let message = localizedText($r('app.string.text_has_not_been_bound_for_application_select'), String(name))
    if (association) {
      try {
        await openAppLink(context, association, href)
        return
      } catch (_) {
        message = localizedText($r('app.string.text_could_not_open_please_confirm_that_the'), String(name))
      }
    }
    if (!this.active || generation !== this.generation) return
    this.getUIContext().showAlertDialog({
      title: association ? localizedText($r('app.string.text_application_cannot_be_opened')) : localizedText($r('app.string.text_the_application_association_has_not_been_configured')),
      message,
      primaryButton: { value: localizedText($r('app.string.text_cancel')), action: (): void => {} },
      secondaryButton: { value: localizedText($r('app.string.text_go_to_settings')), action: (): void => {
        if (!this.active || generation !== this.generation) return
        PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/Settings', params: { section: '应用关联' } })
          .then((opened: boolean): void => { if (!opened) this.notify(localizedText($r('app.string.text_couldn_t_open_app_links_settings_try'))) })
      } }
    })
  }

  @Builder
  emptyContent(_links: LinkController) {}

  @Builder
  mapAppSheet() {
    Column() {
      Text($r('app.string.text_select_map')).fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
        .width('100%').padding({ left: 24, top: 8, bottom: 4 }).textAlign(TextAlign.Start)
      if (this.mapChoices.length > 0) {
        Text(this.mapChoices[0].contextLabel).fontSize(14).fontColor(UiColor.secondary)
          .width('100%').padding({ left: 24, bottom: 10 }).textAlign(TextAlign.Start)
      }
      Divider().color(UiColor.divider).margin({ left: 24, right: 24 })
      ForEach(this.mapChoices, (choice: MapAppChoice) => {
        Row({ space: 12 }) {
          Image(choice.icon).width(36).height(36).objectFit(ImageFit.Contain).borderRadius(8)
            .grayscale(choice.supported ? 0 : 1).opacity(choice.supported ? 1 : 0.5).accessibilityLevel('no')
          Column({ space: 4 }) {
            Text(choice.title).fontSize(20).fontWeight(FontWeight.Medium)
              .fontColor(choice.supported ? UiColor.text : UiColor.disabled)
            Text(choice.description).fontSize(14).fontColor(UiColor.secondary)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          if (choice.supported) {
            Image($r('app.media.ui_next')).width(24).height(24).fillColor(UiColor.primary).accessibilityLevel('no')
          }
        }.width('100%').padding({ left: 24, right: 24, top: 12, bottom: 12 })
          .enabled(!this.launching).onClick((): void => { this.selectMapApp(choice) })
      })
    }.width('100%').backgroundColor(UiColor.surface).borderRadius({ topLeft: 28, topRight: 28 })
  }

  partAt(x: number, y: number): CoreTitlePart | undefined {
    if (!this.openLinks && !this.editable) return undefined
    try {
      const layout = this.textController.getLayoutManager()
      const position = layout.getGlyphPositionAtCoordinate(this.getUIContext().vp2px(x), this.getUIContext().vp2px(y)).position
      let start = 0
      for (const part of this.parts) {
        if (part.count) continue
        const length = part.text.length + (part.isLink && (this.openLinks || this.editable) ? 2 : 0)
        if (position >= start && position < start + length) return part.isLink ? part : undefined
        start += length
      }
    } catch (_) {}
    return undefined
  }

  @Builder
  inlineText() {
    Text(undefined, { controller: this.textController }) {
      if (this.parts.length === 0) {
        Span(this.text).fontColor(this.cancelled ? UiColor.disabled : UiColor.text)
          .decoration({ type: this.cancelled ? TextDecorationType.LineThrough : TextDecorationType.None,
            color: UiColor.disabled })
      } else {
        ForEach(this.parts, (part: CoreTitlePart) => {
          if (part.count) {
          } else if (part.isLink && (this.openLinks || this.editable)) {
            ImageSpan(linkProtocol(part.link?.url || part.href || '').icon).width(this.textSize).height(this.textSize)
              .verticalAlign(ImageSpanAlignment.CENTER)
              .onClick((event: ClickEvent): void => { this.selectPart(part, event) })
            Span('\u2060' + part.text).fontColor(this.cancelled ? UiColor.disabled : part.href ? UiColor.primary : UiColor.secondary)
              .decoration({ type: this.cancelled ? TextDecorationType.LineThrough : TextDecorationType.Underline,
                color: this.cancelled ? UiColor.disabled : undefined,
                style: part.href ? TextDecorationStyle.SOLID : TextDecorationStyle.DASHED })
              .fontWeight(part.styles?.includes('bold') ? FontWeight.Bold : this.weight)
              .fontStyle(part.styles?.includes('italic') ? FontStyle.Italic : FontStyle.Normal)
              .onClick((event: ClickEvent): void => { this.selectPart(part, event) })
          } else {
            Span(part.text).fontColor(this.cancelled ? UiColor.disabled : UiColor.text)
              .fontWeight(part.styles?.includes('bold') ? FontWeight.Bold : this.weight)
              .fontStyle(part.styles?.includes('italic') ? FontStyle.Italic : FontStyle.Normal)
              .fontFamily(part.styles?.includes('code') ? 'monospace' : 'sans-serif')
              .decoration({ type: this.cancelled || part.styles?.includes('strike') ? TextDecorationType.LineThrough :
                part.styles?.includes('underline') ? TextDecorationType.Underline : TextDecorationType.None,
                color: this.cancelled ? UiColor.disabled : undefined })
          }
        })
      }
      if (this.showCounts) {
        ForEach(titleCounts(this.parts), (count: CoreTitleCount) => { titleCountInline(count) })
      }
    }.fontSize(this.textSize).fontWeight(this.weight).fontColor(UiColor.text).lineHeight(this.lineHeight)
      .maxLines(this.lineLimit > 0 ? this.lineLimit : 2147483647).textOverflow({ overflow: TextOverflow.Ellipsis })
      .wordBreak(WordBreak.BREAK_ALL).copyOption(this.copyable ? CopyOptions.LocalDevice : CopyOptions.None)
      .onClick((event: ClickEvent): void => { LinkEditController.protectInteraction(); if (!this.editing && Date.now() >= this.suppressClickUntil) this.activate?.() }).flexShrink(1)
      .gesture(LongPressGesture({ repeat: false, duration: 500 }).onAction((event: GestureEvent): void => {
        const point = event.fingerList[0]
        if (!point) return
        const part = this.partAt(point.localX, point.localY)
        if (part) {
          this.suppressClickUntil = Date.now() + 500
          this.select({ link: part.link, href: part.href || '', label: part.text, x: point.localX, y: point.localY, width: this.widthVp, menu: true })
        }
      }))
      .onGestureJudgeBegin((_info: GestureInfo, event: BaseGestureEvent): GestureJudgeResult => {
        const point = event.fingerList[0]
        return point && this.partAt(point.localX, point.localY) ? GestureJudgeResult.CONTINUE : GestureJudgeResult.REJECT
      })
  }

  build() {
    if (this.document) {
      Stack({ alignContent: Alignment.TopStart }) { this.content(this.links); this.menuAnchor(); this.protocolAnchor() }.width('100%').height(this.contentHeight)
        .onAreaChange((_old: Area, area: Area): void => { this.widthVp = Number(area.width) || 1 })
        .bindSheet($$this.chooserVisible, this.mapAppSheet(), {
          height: SheetSize.FIT_CONTENT, detents: [SheetSize.FIT_CONTENT, '85%'], preferType: SheetType.BOTTOM,
          backgroundColor: UiColor.surface, maskColor: Color.Transparent, showClose: false
        })
    } else {
      Stack({ alignContent: Alignment.TopStart }) {
        Column({ space: 8 }) { this.inlineText(); if (this.editing) { this.linkEditor() } }.alignItems(HorizontalAlign.Start)
        this.menuAnchor()
      }.flexShrink(1).onClick((event: ClickEvent): void => { LinkEditController.protectInteraction() }).onAreaChange((_old: Area, area: Area): void => { this.widthVp = Number(area.width) || 1 })
        .bindSheet($$this.chooserVisible, this.mapAppSheet(), {
          height: SheetSize.FIT_CONTENT, detents: [SheetSize.FIT_CONTENT, '85%'], preferType: SheetType.BOTTOM,
          backgroundColor: UiColor.surface, maskColor: Color.Transparent, showClose: false
        })
    }
  }


}

interface GeoCoordinates {
  latitude: string
  longitude: string
}

// 只操作 Core 提供的安全投影与展示 DOM，不在这里识别、拼接或写回 Org。
export function linkDocumentScript(): string {
  const protocols = LINK_PROTOCOLS.map((choice: LinkProtocolChoice): DocumentLinkProtocol => ({
    kind: choice.kind, title: localizedText(choice.title), prefix: choice.prefix, path: choice.path
  }))
  return `(() => {
    const protocols = ${JSON.stringify(protocols)};
    const labels = ${JSON.stringify({
      title: localizedText($r('app.string.link_editor_title')),
      url: localizedText($r('app.string.link_editor_url')),
      titlePlaceholder: localizedText($r('app.string.link_editor_title_placeholder')),
      urlPlaceholder: localizedText($r('app.string.link_editor_url_placeholder')),
      protocol: localizedText($r('app.string.link_editor_protocol_picker'), '{protocol}'),
      other: localizedText($r('app.string.link_editor_other_protocol')),
      cancel: localizedText($r('app.string.text_cancel')),
      save: localizedText($r('app.string.text_save'))
    })};
    const makeIcon = choice => {
      const icon=document.createElementNS('http://www.w3.org/2000/svg','svg');
      icon.setAttribute('viewBox','0 0 24 24');icon.setAttribute('width','1em');icon.setAttribute('height','1em');
      icon.setAttribute('aria-hidden','true');
      icon.style.cssText='display:inline-block;width:1em;height:1em;flex-shrink:0;vertical-align:-0.12em;pointer-events:none';
      const path=document.createElementNS('http://www.w3.org/2000/svg','path');
      path.setAttribute('d',choice?.path || 'M9 15l6-6M8 11l-2 2a4 4 0 0 0 6 6l2-2M10 7l2-2a4 4 0 0 1 6 6l-2 2');
      path.setAttribute('stroke','currentColor');path.setAttribute('stroke-width','1.7');path.setAttribute('fill','none');
      path.setAttribute('stroke-linecap','round');path.setAttribute('stroke-linejoin','round');
      icon.append(path);return icon;
    };
    const protocol = url => {
      const value = url.trim();
      const kind = value.startsWith('org-internal:') || !value.includes(':') || value.startsWith('#') || value.startsWith('*')
        ? 'internal' : value.substring(0,value.indexOf(':')).toLowerCase();
      return protocols.find(choice => choice.kind === kind);
    };
    const bridge = window.OrgTaskLinks;
    if (!bridge) return;
    const find = link => [...document.querySelectorAll('[data-org-link]')].find(node => {
      try { const value = JSON.parse(node.dataset.orgLink); return value.start === link.start && value.end === link.end && value.source === link.source; }
      catch (_) { return false; }
    });
    const select = (node, menu = false) => {
      let link = null;
      try { link = JSON.parse(node.dataset.orgLink || 'null'); } catch (_) {}
      const rect = node.getBoundingClientRect();
      bridge.hit(JSON.stringify({ link, href: node.getAttribute('href') || '', url: link?.url || node.getAttribute('data-org-url') || node.getAttribute('title') || node.getAttribute('href') || '', label: node.textContent || '', menu,
        x: rect.left + rect.width / 2, y: rect.top, width: window.innerWidth }));
    };
    if (window.orgLinkCleanup) window.orgLinkCleanup();
    let timer, down, suppressUntil = 0;
    const listeners = [];
    const listen = (name, callback) => { document.addEventListener(name,callback,true);listeners.push([name,callback]); };
    const cancelPress = () => { clearTimeout(timer);down = null; };
    listen('click', event => {
      if (event.target.closest('.org-link-editor')) return;
      const node = event.target.closest('.link');
      if (!node) return;
      event.preventDefault(); event.stopPropagation();
      if (Date.now() >= suppressUntil) select(node);
    });
    listen('pointerdown', event => {
      if (event.target.closest('.org-link-editor') || (event.button !== undefined && event.button !== 0)) return;
      const node = event.target.closest('.link');if (!node) return;
      cancelPress();down = { x:event.clientX,y:event.clientY };
      timer = setTimeout(() => { suppressUntil=Date.now()+800;select(node,true);cancelPress(); },500);
    });
    listen('pointermove', event => { if(down && Math.abs(event.clientX-down.x)+Math.abs(event.clientY-down.y)>10)cancelPress(); });
    listen('pointerup',cancelPress);listen('pointercancel',cancelPress);
    listen('contextmenu',event=>{
      const node=event.target.closest('.link');if(!node)return;
      event.preventDefault();event.stopPropagation();cancelPress();
      if(Date.now()>=suppressUntil)select(node,true);suppressUntil=Date.now()+800;
    });
    window.orgLinkCleanup = () => { cancelPress();listeners.forEach(([name,callback])=>document.removeEventListener(name,callback,true)); };
    document.querySelectorAll('.link').forEach(node=>{
      if(node.querySelector('[data-org-link-icon]'))return;
      const url=node.getAttribute('data-org-url') || node.getAttribute('href') || '';
      const icon=makeIcon(protocol(url));icon.setAttribute('data-org-link-icon','true');icon.style.marginRight='3px';
      // 只绑定图标与首个字形，剩余链接仍参与段落换行；保留描述中的富文本。
      const prefix=document.createElement('span');prefix.style.cssText='display:inline-block;white-space:nowrap;text-indent:0';prefix.append(icon);
      const walker=document.createTreeWalker(node,NodeFilter.SHOW_TEXT);let first;
      while((first=walker.nextNode()) && !first.textContent.length){}
      if(first){
        const text=first.textContent;
        const segment=typeof Intl.Segmenter==='function' ? [...new Intl.Segmenter(undefined,{granularity:'grapheme'}).segment(text)][0].segment : Array.from(text)[0];
        const range=document.createRange();range.setStart(node,0);range.setEnd(first,segment.length);prefix.append(range.extractContents());
      }
      node.prepend(prefix);node.style.overflowWrap='anywhere';node.style.wordBreak='break-all';
    });
    window.orgLinkCancel = () => {
      const form = document.querySelector('.org-link-editor');
      if (form) { if (form.previousElementSibling) form.previousElementSibling.hidden = false; form.remove(); }
      window.orgLinkProtocol=undefined;window.orgLinkProtocolState=undefined;
    };
    window.orgLinkEdit = (link, title, url) => {
      const anchor = find(link); if (!anchor) return false;
      window.orgLinkCancel();
      const form = document.createElement('span'); form.className = 'org-link-editor';
      form.style.cssText = 'display:block;margin:8px 0;padding:12px;border-radius:10px;background:${UiColor.surface};color:${UiColor.text};font:14px/1.6 sans-serif;';
      const field = (id, label, value, placeholder) => {
        const name = document.createElement('label'); name.textContent = label; name.style.cssText='display:block;font-size:12px;margin:4px 0;color:${UiColor.secondary}';
        const input = document.createElement('input'); input.value = value; input.placeholder = placeholder;
        input.id = id; name.htmlFor = input.id;
        input.style.cssText='display:block;width:100%;box-sizing:border-box;padding:10px;border:0;border-radius:8px;background:${UiColor.field};color:${UiColor.text};font:14px sans-serif;';
        form.append(name,input); return input;
      };
      const titleInput = field('org-link-title',labels.title,title,labels.titlePlaceholder);
      const urlInput = field('org-link-url',labels.url,url,labels.urlPlaceholder);
      const urlRow=document.createElement('span');urlRow.style.cssText='display:flex;align-items:center;gap:8px;position:relative';
      const protocolButton=document.createElement('button');protocolButton.type='button';
      protocolButton.style.cssText='display:flex;align-items:center;justify-content:center;box-sizing:border-box;flex:0 0 44px;height:44px;padding:6px;border:0;background:transparent;color:${UiColor.primary};font-size:16px';
      protocolButton.setAttribute('aria-expanded','false');protocolButton.setAttribute('aria-haspopup','menu');
      const symbol=document.createElement('span');symbol.style.cssText='display:flex;align-items:center;justify-content:center;box-sizing:border-box;flex:0 0 32px;width:32px;height:32px;padding:8px;border-radius:6px;background:${UiColor.field}';protocolButton.append(symbol);
      const updateProtocol=()=>{
        const current=protocol(urlInput.value);symbol.replaceChildren(makeIcon(current));
        protocolButton.setAttribute('aria-label',labels.protocol.replace('{protocol}', () => current?.title || labels.other));
      };
      window.orgLinkProtocolState=visible=>protocolButton.setAttribute('aria-expanded',String(visible));
      window.orgLinkProtocol=value=>{
        urlInput.value=value;updateProtocol();window.orgLinkProtocolState(false);draft();urlInput.focus();return true;
      };
      protocolButton.addEventListener('click',event=>{
        event.preventDefault();event.stopPropagation();
        const rect=protocolButton.getBoundingClientRect();draft();
        bridge.protocol(JSON.stringify({title:titleInput.value,url:urlInput.value,x:rect.left+rect.width/2,y:rect.bottom,
          width:window.innerWidth,height:window.visualViewport?.height || window.innerHeight}));
      });
      urlInput.before(urlRow);urlRow.append(protocolButton,urlInput);urlInput.style.flex='1';urlInput.style.minWidth='0';
      updateProtocol();
      titleInput.enterKeyHint = 'next'; urlInput.enterKeyHint = 'done';
      const status = document.createElement('span'); status.className='org-link-status'; status.style.cssText='display:block;color:${UiColor.error};font-size:12px';form.append(status);
      const controls = document.createElement('span');controls.style.cssText='display:flex;justify-content:flex-end;gap:12px;margin-top:10px';form.append(controls);
      const draft = () => bridge.draft(titleInput.value,urlInput.value);
      titleInput.addEventListener('input',draft);urlInput.addEventListener('input',()=>{updateProtocol();draft();});
      form.addEventListener('click',event=>event.stopPropagation());
      for (const input of [titleInput,urlInput]) {
        input.addEventListener('keydown',event=>{
          if (event.key !== 'Enter' || event.isComposing) return;
          event.preventDefault(); event.stopPropagation();
          if (input === titleInput) urlInput.focus();
          else { draft(); bridge.save(titleInput.value,urlInput.value); }
        });
      }
      for (const action of ['cancel','save']) {
        const button = document.createElement('button');button.type='button';button.textContent=labels[action];
        button.style.cssText='min-height:40px;padding:6px 16px;border:0;border-radius:8px;background:${UiColor.field};color:${UiColor.text};font:14px sans-serif;';
        button.addEventListener('click',event=>{event.preventDefault();event.stopPropagation();draft();action==='save'?bridge.save(titleInput.value,urlInput.value):bridge.cancel();});controls.append(button);
      }
      anchor.after(form);anchor.hidden=true;titleInput.focus();return true;
    };
    window.orgLinkStatus = (message,busy) => {
      const form=document.querySelector('.org-link-editor');if(!form)return;
      form.querySelector('.org-link-status').textContent=message;
      form.querySelectorAll('input,button,select').forEach(node=>node.disabled=busy);
    };
  })()`
}

// 链接解析由 Core 完成；宿主只调用系统能力打开支持的外部地址。
async function openExternalLink(context: common.UIAbilityContext, href: string, chooser: (choices: MapAppChoice[]) => void): Promise<void> {
  const scheme = href.substring(0, href.indexOf(':')).toLowerCase()
  if (scheme === 'http' || scheme === 'https') {
    await context.openLink(href, { appLinkingOnly: false })
  } else if (scheme === 'mailto' || scheme === 'tel') {
    try { await context.startAbility({ action: 'ohos.want.action.viewData', uri: href }) }
    catch (error) { throw new Error(localizedText($r('app.string.text_couldn_t_open_the_link_make_sure'))) }
  } else if (scheme === 'geo') {
    const search = geoSearchAddress(href)
    if (search) {
      await openMapChooser(context, `geo:0,0?q=${encodeURIComponent(search)}`, chooser)
    } else if (geoIsZero(href)) {
      throw new Error(localizedText($r('app.string.text_address_link_missing_q_search_parameters')))
    } else {
      await openMapChooser(context, href, chooser)
    }
  } else if (scheme === 'addr') {
    // Core 已将地址文字按 URI 规则编码；转换为标准 geo 查询后交给系统选择器。
    const address = decodeURIComponent(href.substring(href.indexOf(':') + 1))
    await openMapChooser(context, `geo:0,0?q=${encodeURIComponent(address)}`, chooser)
  } else {
    throw new Error(localizedText($r('app.string.text_this_link_is_not_supported_for_opening')))
  }
}

async function openMapChooser(context: common.UIAbilityContext, uri: string, chooser: (choices: MapAppChoice[]) => void): Promise<void> {
  const choices: MapAppChoice[] = [
    mapChoice(context, localizedText($r('app.string.text_amap')), $r('app.media.map_app_amap'), 'com.amap.hmapp', uri),
    mapChoice(context, localizedText($r('app.string.text_petal_maps')), $r('app.media.map_app_petal'), 'com.huawei.hmos.maps.app', uri)
  ]
  chooser(choices)
}

function geoIsZero(href: string): boolean {
  const colon = href.indexOf(':')
  const query = href.indexOf('?')
  const coordinates = href.substring(colon + 1, query < 0 ? href.length : query)
  return /^0(?:\.0+)?\s*,\s*0(?:\.0+)?$/.test(coordinates)
}

function mapChoice(context: common.UIAbilityContext, title: string, icon: Resource, bundleName: string,
  uri: string): MapAppChoice {
  const search = geoSearchAddress(uri)
  const coordinates = geoCoordinates(uri)
  const contextLabel = search ? localizedText($r('app.string.text_search'), String(search)) : coordinates ? localizedText($r('app.string.text_coordinate'), String(coordinates.latitude), String(coordinates.longitude)) : localizedText($r('app.string.text_address'))
  const supported = !(bundleName === 'com.amap.hmapp' && Boolean(search))
  return {
    title,
    icon,
    contextLabel,
    description: search ? (supported ? localizedText($r('app.string.text_search_for_addresses_in_maps')) : localizedText($r('app.string.text_address_search_is_unavailable'))) : localizedText($r('app.string.text_open_coordinates_on_the_map')),
    supported,
    select: async (): Promise<void> => {
      if (bundleName === 'com.huawei.hmos.maps.app' && search) {
        await petalMaps.openMapTextSearch(context, { destinationName: search })
        return
      }
      if (bundleName === 'com.amap.hmapp' && search) {
        await context.openLink(`https://uri.amap.com/search?keyword=${encodeURIComponent(search)}`, { appLinkingOnly: false })
        return
      }
      const targetUri = bundleName === 'com.amap.hmapp' ? amapUri(uri, search) : uri
      const want: Want = { bundleName, abilityName: 'EntryAbility', action: 'ohos.want.action.viewData', uri: targetUri,
        entities: ['entity.system.browsable'] } as Want
      await context.startAbility(want)
    }
  }
}

function amapUri(uri: string, search: string | undefined): string {
  const coordinates = geoCoordinates(uri)
  if (coordinates) {
    return `amapuri://route/plan?dlat=${coordinates.latitude}&dlon=${coordinates.longitude}&dev=0&t=0`
  }
  return `amapuri://route/plan?dname=${encodeURIComponent(search || '')}&dev=0&t=0`
}

function geoCoordinates(uri: string): GeoCoordinates | undefined {
  const colon = uri.indexOf(':')
  const query = uri.indexOf('?')
  const value = uri.substring(colon + 1, query < 0 ? uri.length : query)
  const parts = value.split(',')
  if (parts.length !== 2 || parts[0] === '0' || parts[1] === '0') return undefined
  const result: GeoCoordinates = { latitude: parts[0], longitude: parts[1] }
  return result
}

function geoSearchAddress(href: string): string | undefined {
  const colon = href.indexOf(':')
  const query = href.indexOf('?')
  if (colon < 0 || query < 0 || href.substring(colon + 1, query) !== '0,0') return undefined
  for (const part of href.substring(query + 1).split('&')) {
    const equals = part.indexOf('=')
    if (equals < 0 || part.substring(0, equals) !== 'q') continue
    const value = part.substring(equals + 1).replace(/\+/g, ' ')
    if (!value) return undefined
    return decodeURIComponent(value)
  }
  return undefined
}
