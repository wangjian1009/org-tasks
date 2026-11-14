import { common, Want } from '@kit.AbilityKit'
import { petalMaps } from '@kit.MapKit'
import { webview } from '@kit.ArkWeb'
import { CoreTitlePart, CoreTextLink, CoreLinkValue } from '../services/NativeCoreService'
import { UiColor, UiSize } from '../ui/Theme'

interface MapAppChoice {
  title: string
  icon: Resource
  contextLabel: string
  description: string
  supported: boolean
  select: () => Promise<void>
}

interface LinkHit {
  link: CoreTextLink | null
  href: string
  label: string
  x: number
  y: number
  width: number
}

// 同一任务中的标题和备注共享结束输入入口，保存失败时阻止收起及其他字段操作。
export class LinkEditController {
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
  @Prop lineLimit: number = 0
  @Prop cancelled: boolean = false
  @Prop copyable: boolean = false
  @Prop openLinks: boolean = true
  @Prop editable: boolean = false
  @Prop revision: string = ''
  @Prop document: boolean = false
  @Prop contentHeight: number | string = '100%'
  activate: (() => void) | undefined = undefined
  change: ((link: CoreTextLink, value: CoreLinkValue | null) => Promise<void>) | undefined = undefined
  editingChanged: (editing: boolean) => void = () => {}
  editor: LinkEditController = new LinkEditController()
  webController: webview.WebviewController | undefined = undefined
  remeasure: () => void = () => {}
  @BuilderParam content: (links: LinkController) => void = this.emptyContent
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
  private links: LinkController = new LinkController((href: string): Promise<void> => this.navigate(href))

  aboutToAppear() {
    this.active = true; this.generation++; this.launching = false
    this.owner = this.getUniqueId()
    this.editor.bind(this.owner, async (): Promise<boolean> => !this.editing || await this.saveEdit())
    this.links.hit = (payload: string): void => { this.webHit(payload) }
    this.links.draft = (title: string, url: string): void => { if (this.editing && !this.saving) { this.titleDraft = title; this.urlDraft = url } }
    this.links.save = (title: string, url: string): void => {
      if (!this.editing || this.saving) return
      this.titleDraft = title; this.urlDraft = url; this.saveEdit()
    }
    this.links.cancel = (): void => { this.cancelEdit() }
    this.links.ready = (): void => { this.installDocument() }
  }
  aboutToDisappear() {
    this.active = false; this.generation++; this.chooserVisible = false; this.mapChoices = []; this.menuVisible = false
    this.editor.release(this.owner)
    if (this.editing) this.editingChanged(false)
  }

  async navigate(href: string): Promise<void> {
    if (!this.editable) { await this.open(href); return }
    if (!this.webController) return
    try {
      await this.webController.runJavaScript(`window.orgLinkSelectByHref?.(${JSON.stringify(href)})`)
    } catch (_) { this.notify('链接尚未载入，请稍后重试。') }
  }

  select(hit: LinkHit) {
    if (!this.active || this.saving || this.editing) return
    if (!this.editable) { this.open(hit.href); return }
    if (!hit.link) { this.notify('链接位置不可用，请重新载入后重试。'); return }
    this.selected = hit; this.selectedRevision = this.revision; this.editError = ''; this.menuVisible = true
  }

  selectPart(part: CoreTitlePart, event: ClickEvent) {
    this.select({ link: part.link, href: part.href || '', label: part.text, x: event.x, y: event.y, width: this.widthVp })
  }

  webHit(payload: string) {
    if (!this.active) return
    try {
      const hit = JSON.parse(payload) as LinkHit
      this.select(hit)
    } catch (_) { this.notify('无法读取链接，请重新载入正文。') }
  }

  async installDocument() {
    if (!this.active || !this.webController) return
    try { await this.webController.runJavaScript(linkDocumentScript(this.editable)) }
    catch (_) { this.notify('链接控件加载失败，请重新载入正文。') }
  }

  async beginEdit() {
    if (!this.active || !this.editable || !this.selected?.link || this.saving) return
    const generation = this.generation
    const selected = this.selected
    if (!await this.editor.finish(this.owner) || !this.active || !this.editable || generation !== this.generation
      || selected !== this.selected || this.revision !== this.selectedRevision) return
    this.menuVisible = false
    this.titleDraft = this.selected.link.title; this.urlDraft = this.selected.link.url
    this.editError = ''; this.editing = true; this.editingChanged(true)
    if (this.document && this.webController) {
      this.webController.runJavaScript(`window.orgLinkEdit?.(${JSON.stringify(this.selected.link)}, ${JSON.stringify(this.titleDraft)}, ${JSON.stringify(this.urlDraft)})`)
        .then((): void => { this.remeasure() }).catch((): void => { this.editError = '无法展开链接编辑，请重试。' })
    }
  }

  cancelEdit() {
    if (this.saving) return
    this.menuVisible = false; this.editing = false; this.editError = ''; this.editingChanged(false)
    if (this.webController) this.webController.runJavaScript('window.orgLinkCancel?.()').then((): void => { this.remeasure() }).catch(() => {})
  }

  async commit(value: CoreLinkValue | null): Promise<boolean> {
    if (!this.active || !this.selected?.link || this.saving) return false
    const generation = this.generation
    const selected = this.selected
    if (!value && !await this.editor.finish(this.owner)) return false
    if (!this.active || generation !== this.generation || selected !== this.selected) return false
    if (!this.editable || !this.change) { this.editError = '当前链接无法修改，请取消编辑并重新载入。'; this.notify(this.editError); this.documentStatus(this.editError, false); return false }
    if (this.revision !== this.selectedRevision) { this.editError = '内容已变化，请取消编辑并重新载入后重试。'; this.notify(this.editError); this.documentStatus(this.editError, false); return false }
    if (value && !value.url.trim()) { this.editError = '链接不能为空'; this.notify(this.editError); this.documentStatus(this.editError, false); return false }
    this.saving = true; this.menuVisible = false; this.editError = ''
    this.documentStatus('', true)
    try {
      await this.change(this.selected.link, value)
      if (!this.active || generation !== this.generation) return true
      this.saving = false; this.cancelEdit()
      return true
    } catch (error) {
      if (this.active && generation === this.generation) {
        this.editError = (error as Error).message || '保存链接失败，请重试。'
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
    if (this.selected?.link && this.titleDraft === this.selected.link.title && this.urlDraft === this.selected.link.url) {
      this.cancelEdit(); return true
    }
    return await this.commit({ title: this.titleDraft, url: this.urlDraft })
  }

  @Builder
  linkMenu() {
    Row() {
      Button('跳转').fontSize(14).fontColor(UiColor.text).height(44).padding({ left: 16, right: 16 })
        .backgroundColor(Color.Transparent).enabled(this.openLinks && !!this.selected?.href)
        .onClick((): void => { this.menuVisible = false; if (this.selected?.href) this.open(this.selected.href) })
      Button('编辑').fontSize(14).fontColor(UiColor.text).height(44).padding({ left: 16, right: 16 })
        .backgroundColor(Color.Transparent).onClick((): void => { this.beginEdit() })
      Button('删除').fontSize(14).fontColor(UiColor.error).height(44).padding({ left: 16, right: 16 })
        .backgroundColor(Color.Transparent).onClick((): void => { this.commit(null) })
    }.backgroundColor(UiColor.menu).borderRadius(10)
  }

  @Builder
  menuAnchor() {
    Row().width(1).height(1).position({ x: Math.max(0, Math.min(this.widthVp - 1, (this.selected?.x || 0) * this.widthVp / (this.selected?.width || this.widthVp))),
      y: Math.max(0, (this.selected?.y || 0) * this.widthVp / (this.selected?.width || this.widthVp)) })
      .bindPopup(this.menuVisible, { builder: this.linkMenu(), placement: Placement.Top,
        targetSpace: 6, enableArrow: true, popupColor: UiColor.menu, backgroundBlurStyle: BlurStyle.NONE,
        mask: { color: Color.Transparent }, autoCancel: true, onStateChange: (event): void => { this.menuVisible = event.isVisible } })
  }

  @Builder
  linkEditor() {
    Column({ space: 8 }) {
      Text('标题').fontSize(12).fontColor(UiColor.secondary).width('100%')
      TextInput({ text: this.titleDraft, placeholder: '无标题时显示链接地址' }).fontSize(14).fontColor(UiColor.text)
        .accessibilityText('链接标题')
        .backgroundColor(UiColor.field).enabled(!this.saving).onChange((value: string): void => { this.titleDraft = value })
      Text('链接').fontSize(12).fontColor(UiColor.secondary).width('100%')
      TextInput({ text: this.urlDraft, placeholder: '链接地址' }).fontSize(14).fontColor(UiColor.text)
        .accessibilityText('链接地址')
        .backgroundColor(UiColor.field).enabled(!this.saving).onChange((value: string): void => { this.urlDraft = value })
      if (this.editError) { Text(this.editError).fontSize(12).fontColor(UiColor.error).width('100%') }
      Row({ space: 12 }) {
        Button('取消').height(40).fontSize(14).fontColor(UiColor.text).backgroundColor(UiColor.field)
          .enabled(!this.saving).onClick((): void => { this.cancelEdit() })
        Button('保存').height(40).fontSize(14).fontColor(UiColor.text).backgroundColor(UiColor.field)
          .enabled(!this.saving).onClick((): void => { this.saveEdit() })
      }.justifyContent(FlexAlign.End).width('100%')
    }.width('100%').padding(12).borderRadius(10).backgroundColor(UiColor.surface)
  }

  async open(href: string): Promise<void> {
    if (!this.active || !this.openLinks || this.launching) return
    const generation = this.generation
    this.launching = true
    try {
      await openExternalLink(this.getUIContext().getHostContext()! as common.UIAbilityContext, href,
        (choices: MapAppChoice[]): void => {
          if (this.active && generation === this.generation) { this.mapChoices = choices; this.chooserVisible = true }
        })
    } catch (_) {
      if (generation === this.generation) this.notify('无法打开链接，请确认地址有效且已安装对应应用。')
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
      this.notify('高德地图暂不支持地址搜索，请选择花瓣地图。')
      return
    }
    this.launching = true
    try {
      await choice.select()
      if (this.active && generation === this.generation) this.chooserVisible = false
    } catch (_) {
      if (generation === this.generation) this.notify('无法打开地图，请确认已安装对应应用后重试。')
    } finally {
      if (this.active && generation === this.generation) this.launching = false
    }
  }

  @Builder
  emptyContent(_links: LinkController) {}

  @Builder
  mapAppSheet() {
    Column() {
      Text('选择地图').fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
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

  @Builder
  inlineText() {
    Text() {
      if (this.parts.length === 0) {
        Span(this.text).fontColor(this.cancelled ? UiColor.disabled : UiColor.text)
          .decoration({ type: this.cancelled ? TextDecorationType.LineThrough : TextDecorationType.None })
      } else {
        ForEach(this.parts, (part: CoreTitlePart) => {
          if (part.count) {
          } else if (this.editable && part.isLink) {
            Span(part.text).fontColor(this.cancelled ? UiColor.disabled : part.href ? UiColor.primary : UiColor.secondary)
              .decoration({ type: this.cancelled ? TextDecorationType.LineThrough : TextDecorationType.Underline,
                style: part.href ? TextDecorationStyle.SOLID : TextDecorationStyle.DASHED })
              .onClick((event: ClickEvent): void => { this.selectPart(part, event) })
          } else if (part.href && this.openLinks) {
            Span(part.text).fontColor(this.cancelled ? UiColor.disabled : UiColor.primary)
              .decoration({ type: this.cancelled ? TextDecorationType.LineThrough : TextDecorationType.Underline })
              .onClick((): void => { this.links.open(part.href!) })
          } else if (part.isLink && this.openLinks) {
            Span(part.text).fontColor(this.cancelled ? UiColor.disabled : UiColor.secondary)
              .decoration({ type: this.cancelled ? TextDecorationType.LineThrough : TextDecorationType.Underline,
                color: UiColor.secondary, style: TextDecorationStyle.DASHED })
          } else {
            Span(part.text).fontColor(this.cancelled ? UiColor.disabled : UiColor.text)
              .decoration({ type: this.cancelled ? TextDecorationType.LineThrough : TextDecorationType.None })
          }
        })
      }
    }.fontSize(this.textSize).fontWeight(this.weight).fontColor(UiColor.text)
      .maxLines(this.lineLimit > 0 ? this.lineLimit : 2147483647).textOverflow({ overflow: TextOverflow.Ellipsis })
      .wordBreak(WordBreak.BREAK_ALL).copyOption(this.copyable ? CopyOptions.LocalDevice : CopyOptions.None)
      .onClick((): void => { if (!this.editing) this.activate?.() }).flexShrink(1)
  }

  build() {
    if (this.document) {
      Stack({ alignContent: Alignment.TopStart }) { this.content(this.links); this.menuAnchor() }.width('100%').height(this.contentHeight)
        .onAreaChange((_old: Area, area: Area): void => { this.widthVp = Number(area.width) || 1 })
        .bindSheet($$this.chooserVisible, this.mapAppSheet(), {
          height: SheetSize.FIT_CONTENT, detents: [SheetSize.FIT_CONTENT, '85%'], preferType: SheetType.BOTTOM,
          backgroundColor: UiColor.surface, maskColor: Color.Transparent, showClose: false
        })
    } else {
      Stack({ alignContent: Alignment.TopStart }) {
        Column({ space: 8 }) { this.inlineText(); if (this.editing) { this.linkEditor() } }.alignItems(HorizontalAlign.Start)
        this.menuAnchor()
      }.flexShrink(1).onAreaChange((_old: Area, area: Area): void => { this.widthVp = Number(area.width) || 1 })
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
export function linkDocumentScript(editable: boolean): string {
  return `(() => {
    const editable = ${editable};
    const bridge = window.OrgTaskLinks;
    if (!bridge) return;
    const find = link => [...document.querySelectorAll('[data-org-link]')].find(node => {
      try { const value = JSON.parse(node.dataset.orgLink); return value.start === link.start && value.end === link.end && value.source === link.source; }
      catch (_) { return false; }
    });
    const select = node => {
      let link = null;
      try { link = JSON.parse(node.dataset.orgLink || 'null'); } catch (_) {}
      if (editable && !link) return;
      const rect = node.getBoundingClientRect();
      bridge.hit(JSON.stringify({ link, href: node.getAttribute('href') || '', label: node.textContent || '',
        x: rect.left + rect.width / 2, y: rect.top, width: window.innerWidth }));
    };
    if (window.orgLinkClick) document.removeEventListener('click', window.orgLinkClick, true);
    window.orgLinkClick = event => {
      if (event.target.closest('.org-link-editor')) return;
      const node = event.target.closest(editable ? '[data-org-link]' : 'a.link');
      if (!node) return;
      event.preventDefault(); event.stopPropagation(); select(node);
    };
    document.addEventListener('click', window.orgLinkClick, true);
    window.orgLinkSelectByHref = href => {
      const node = [...document.querySelectorAll('a.link')].find(node => node.href === href || node.getAttribute('href') === href);
      if (node) select(node);
    };
    window.orgLinkCancel = () => {
      const form = document.querySelector('.org-link-editor');
      if (form) { if (form.previousElementSibling) form.previousElementSibling.hidden = false; form.remove(); }
    };
    window.orgLinkEdit = (link, title, url) => {
      const anchor = find(link); if (!anchor) return false;
      window.orgLinkCancel();
      const form = document.createElement('span'); form.className = 'org-link-editor';
      form.style.cssText = 'display:block;margin:8px 0;padding:12px;border-radius:10px;background:${UiColor.surface};color:${UiColor.text};font:14px/1.6 sans-serif;';
      const field = (label, value, placeholder) => {
        const name = document.createElement('label'); name.textContent = label; name.style.cssText='display:block;font-size:12px;margin:4px 0;color:${UiColor.secondary}';
        const input = document.createElement('input'); input.value = value; input.placeholder = placeholder;
        input.id = label === '标题' ? 'org-link-title' : 'org-link-url'; name.htmlFor = input.id;
        input.style.cssText='display:block;width:100%;box-sizing:border-box;padding:10px;border:0;border-radius:8px;background:${UiColor.field};color:${UiColor.text};font:14px sans-serif;';
        form.append(name,input); return input;
      };
      const titleInput = field('标题',title,'无标题时显示链接地址');
      const urlInput = field('链接',url,'链接地址');
      const status = document.createElement('span'); status.className='org-link-status'; status.style.cssText='display:block;color:${UiColor.error};font-size:12px';form.append(status);
      const controls = document.createElement('span');controls.style.cssText='display:flex;justify-content:flex-end;gap:12px;margin-top:10px';form.append(controls);
      const draft = () => bridge.draft(titleInput.value,urlInput.value);
      titleInput.addEventListener('input',draft);urlInput.addEventListener('input',draft);
      for (const label of ['取消','保存']) {
        const button = document.createElement('button');button.type='button';button.textContent=label;
        button.style.cssText='min-height:40px;padding:6px 16px;border:0;border-radius:8px;background:${UiColor.field};color:${UiColor.text};font:14px sans-serif;';
        button.addEventListener('click',event=>{event.preventDefault();event.stopPropagation();draft();label==='保存'?bridge.save(titleInput.value,urlInput.value):bridge.cancel();});controls.append(button);
      }
      anchor.after(form);anchor.hidden=true;titleInput.focus();return true;
    };
    window.orgLinkStatus = (message,busy) => {
      const form=document.querySelector('.org-link-editor');if(!form)return;
      form.querySelector('.org-link-status').textContent=message;
      form.querySelectorAll('input,button').forEach(node=>node.disabled=busy);
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
    catch (error) { throw new Error('无法打开链接，请确认已安装对应应用。') }
  } else if (scheme === 'geo') {
    const search = geoSearchAddress(href)
    if (search) {
      await openMapChooser(context, `geo:0,0?q=${encodeURIComponent(search)}`, chooser)
    } else if (geoIsZero(href)) {
      throw new Error('地址链接缺少 q 搜索参数')
    } else {
      await openMapChooser(context, href, chooser)
    }
  } else if (scheme === 'addr') {
    // Core 已将地址文字按 URI 规则编码；转换为标准 geo 查询后交给系统选择器。
    const address = decodeURIComponent(href.substring(href.indexOf(':') + 1))
    await openMapChooser(context, `geo:0,0?q=${encodeURIComponent(address)}`, chooser)
  } else {
    throw new Error('此链接暂不支持打开')
  }
}

async function openMapChooser(context: common.UIAbilityContext, uri: string, chooser: (choices: MapAppChoice[]) => void): Promise<void> {
  const choices: MapAppChoice[] = [
    mapChoice(context, '高德地图', $r('app.media.map_app_amap'), 'com.amap.hmapp', uri),
    mapChoice(context, '花瓣地图', $r('app.media.map_app_petal'), 'com.huawei.hmos.maps.app', uri)
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
  const contextLabel = search ? `搜索：${search}` : coordinates ? `坐标：${coordinates.latitude}, ${coordinates.longitude}` : '地址'
  const supported = !(bundleName === 'com.amap.hmapp' && Boolean(search))
  return {
    title,
    icon,
    contextLabel,
    description: search ? (supported ? '在地图中搜索地址' : '暂不支持地址搜索') : '在地图中打开坐标',
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
