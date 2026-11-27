import { common } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { webview } from '@kit.ArkWeb'
import { pasteboard } from '@kit.BasicServicesKit'
import { SettingsGroup } from '../components/controls/SettingsGroup'
import { SettingsRow } from '../components/controls/SettingsRow'
import { CoreArticleSection, renderArticle } from '../services/NativeCoreService'
import uiAppearance from '@ohos.uiAppearance'
import { PageNavigator } from '../services/PageNavigator'
import { bundledLocale, localizedText } from '../ui/LocalizedText'
import { helpDocument } from '../ui/HelpPresentation'
import { UiColor } from '../ui/Theme'

interface HelpTopic { id: string; title: string }
interface HelpEntry { id: string; topic: string; title: string; summary: string; keywords: string[]; frequent?: boolean }
interface HelpIndex { topics: HelpTopic[]; articles: HelpEntry[] }
interface HelpParams { article?: string; topic?: string; anchor?: string }

@Entry
@Component
struct Help {
  @State private topics: HelpTopic[] = []
  @State private entries: HelpEntry[] = []
  @State private article: string = ''
  @State private topic: string = ''
  @State private query: string = ''
  @State private sections: CoreArticleSection[] = []
  @State private selectedSection: string = ''
  @State private loading: boolean = true
  @State private failed: boolean = false
  @State private directoryOpen: boolean = false
  @State private imageOpen: boolean = false
  @State private imageSource: string = ''
  @State private imageScale: number = 1
  @State private zoomRatio: number = 100
  private anchor = ''
  private html = ''
  private requested = false
  private active = false
  private imageSources = new Map<string, string>()
  private controller = new webview.WebviewController()

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as HelpParams | undefined
    this.article = params?.article ?? ''
    this.topic = params?.topic ?? ''
    this.anchor = params?.anchor ?? ''
    this.active = true
    this.load()
  }

  onPageShow(): void {
    try { this.zoomRatio = Math.round(uiAppearance.getFontScale() * 100) }
    catch (_) { this.zoomRatio = 100 }
  }

  aboutToDisappear(): void {
    this.active = false
  }

  private async load(): Promise<void> {
    this.loading = true
    this.failed = false
    try {
      const resources = this.getUIContext().getHostContext()!.resourceManager
      const language = bundledLocale()
      const directory = `app-docs/${language}`
      const source = await resources.getRawFileContent(`${directory}/index.json`)
      const index = JSON.parse(util.TextDecoder.create('utf-8').decodeToString(source)) as HelpIndex
      if (this.article) {
        if (!index.articles.some((entry: HelpEntry): boolean => entry.id === this.article)) {
          throw new Error('帮助文章不存在')
        }
        const content = await resources.getRawFileContent(`${directory}/${this.article}.org`)
        const article = await renderArticle(content)
        let fragment = article.html
        for (const image of article.images) {
          try {
            const bytes = await resources.getRawFileContent(`${directory}/${image}`)
            const extension = image.substring(image.lastIndexOf('.') + 1)
            const mime = extension === 'jpg' ? 'jpeg' : extension
            const encoded = `data:image/${mime};base64,${new util.Base64Helper().encodeToStringSync(bytes)}`
            this.imageSources.set(image, encoded)
            fragment = fragment.split(`src="org-help-image:${image}"`).join(`src="${encoded}"`)
          } catch (_) {
            // 文章继续显示图片的替代文字和其他内容。
          }
        }
        this.html = helpDocument(fragment, language)
        this.sections = article.sections
        this.selectedSection = article.sections[0]?.id ?? ''
        this.requested = false
      }
      if (!this.active) return
      this.topics = index.topics
      this.entries = index.articles
    } catch (_) {
      if (this.active) this.failed = true
    } finally {
      if (this.active) this.loading = false
    }
  }

  private openArticle(id: string, anchor: string = ''): void {
    if (!this.entries.some((entry: HelpEntry): boolean => entry.id === id)) {
      this.unavailable()
      return
    }
    PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/Help', params: { article: id, anchor } })
  }

  private unavailable(): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: localizedText($r('app.string.help_link_unavailable')) })
    } catch (_) {
      // 窗口关闭后不再显示提示。
    }
  }

  private async showDirectory(): Promise<void> {
    const ids = this.sections.map((section: CoreArticleSection): string => section.id)
    try {
      const result = await this.controller.runJavaScript(`(() => {
        const headings = ${JSON.stringify(ids)}.map(id => document.getElementById(id)).filter(Boolean);
        return headings.filter(el => el.getBoundingClientRect().top <= 32).pop()?.id ?? headings[0]?.id ?? '';
      })()`)
      this.selectedSection = result.replace(/^"|"$/g, '')
    } catch (_) {
      // 内容尚未绘制时仍提供文章目录。
    }
    if (this.active) this.directoryOpen = true
  }

  private async jump(section: CoreArticleSection): Promise<void> {
    this.selectedSection = section.id
    try {
      await this.controller.runJavaScript(`document.getElementById(${JSON.stringify(section.id)})?.scrollIntoView()`)
    } catch (_) {
      this.unavailable()
    }
  }

  private jumpToAnchor(anchor: string): void {
    const section = this.sections.find((item: CoreArticleSection): boolean => item.target === anchor || item.id === anchor)
    if (section) this.jump(section)
    else this.unavailable()
  }

  private pageEnded(): void {
    if (!this.requested) {
      this.requested = true
      try {
        this.controller.loadData(encodeURIComponent(this.html), 'text/html', 'UTF-8')
      } catch (_) {
        this.failed = true
      }
      return
    }
    this.addCopyButtons()
    if (this.anchor) {
      const anchor = this.anchor
      this.anchor = ''
      this.jumpToAnchor(anchor)
    }
  }

  private async addCopyButtons(): Promise<void> {
    const label = localizedText($r('app.string.help_copy_example'))
    try {
      await this.controller.runJavaScript(`document.querySelectorAll('pre').forEach((block, index) => {
        if (block.id) return;
        block.id = 'example-' + index;
        const link = document.createElement('a');
        link.href = 'org-help-copy:' + block.id;
        link.className = 'example-copy';
        link.textContent = ${JSON.stringify(label)};
        block.before(link);
      })`)
    } catch (_) {
      // 系统文本选择仍可复制示例。
    }
  }

  private async copyExample(id: string): Promise<void> {
    if (!/^example-\d+$/.test(id)) return
    try {
      const result = await this.controller.runJavaScript(
        `document.getElementById(${JSON.stringify(id)})?.textContent ?? ''`)
      const value = JSON.parse(result) as string
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value))
    } catch (_) {
      this.unavailable()
    }
  }

  private openLink(href: string): boolean {
    if (href === 'about:blank' || href.startsWith('data:text/html')) return false
    if (href.startsWith('org-help-copy:')) {
      this.copyExample(href.substring('org-help-copy:'.length))
    } else if (href.startsWith('org-help-anchor:')) {
      this.jumpToAnchor(href.substring('org-help-anchor:'.length))
    } else if (href.startsWith('org-help-article:')) {
      const parts = href.substring('org-help-article:'.length).split('#')
      this.openArticle(parts[0], parts[1] ?? '')
    } else if (href.startsWith('org-help-image:')) {
      const image = this.imageSources.get(href.substring('org-help-image:'.length))
      if (image) {
        this.imageSource = image
        this.imageScale = 1
        this.imageOpen = true
      } else this.unavailable()
    } else if (href === 'orgtasks://page/task-reminders') {
      PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/Settings', params: { section: '任务提醒' } })
    } else if (href === 'orgtasks://page/file-entries') {
      PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/Settings', params: { section: '文件入口' } })
    } else if (href === 'orgtasks://page/help-center') {
      PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/Help' })
    } else if (href.startsWith('https://') || href.startsWith('http://')) {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext
      context.openLink(href, { appLinkingOnly: false }).catch((): void => { this.unavailable() })
    } else {
      this.unavailable()
    }
    return true
  }

  private entryDetail(entry: HelpEntry): string {
    const topic = this.topics.find((item: HelpTopic): boolean => item.id === entry.topic)
    return topic ? `${topic.title} · ${entry.summary}` : entry.summary
  }

  private matchingEntries(): HelpEntry[] {
    const terms = this.query.toLowerCase().trim().split(/\s+/)
    return this.entries.filter((entry: HelpEntry): boolean => {
      const category = this.topics.find((topic: HelpTopic): boolean => topic.id === entry.topic)?.title ?? ''
      const searchable = [entry.title, entry.summary, category, ...entry.keywords].join(' ').toLowerCase()
      return entry.topic.length > 0 && (!this.topic || entry.topic === this.topic) &&
        terms.every((term: string): boolean => searchable.includes(term))
    })
  }

  onBackPress(): boolean {
    if (this.imageOpen) this.imageOpen = false
    else if (this.directoryOpen) this.directoryOpen = false
    else PageNavigator.shared.back(this.getUIContext())
    return true
  }

  @Builder
  private directory() {
    Column() {
      Row() {
        Text($r('app.string.help_article_contents')).fontSize(22).fontColor(UiColor.text).layoutWeight(1)
        Button($r('app.string.text_close')).type(ButtonType.Normal).backgroundColor(Color.Transparent)
          .fontColor(UiColor.primary).onClick((): void => { this.directoryOpen = false })
      }.width('100%').height(52)
      Scroll() {
        Column() {
          ForEach(this.sections, (section: CoreArticleSection) => {
            Text(section.title).fontSize(17).fontColor(section.id === this.selectedSection ? UiColor.primary : UiColor.text)
              .width('100%').constraintSize({ minHeight: 50 })
              .padding({ left: 12 * Math.min(section.level - 1, 4), top: 9, bottom: 9 })
              .border({ width: { bottom: 0.5 }, color: UiColor.divider })
              .onClick((): void => { this.directoryOpen = false; this.jump(section) })
          }, (section: CoreArticleSection): string => section.id)
        }.width('100%')
      }.align(Alignment.TopStart).layoutWeight(1).width('100%')
    }.width('100%').height('100%').padding({ left: 24, right: 24, bottom: 16 })
  }

  @Builder
  private imagePreview() {
    Column() {
      Row() {
        Button($r('app.string.text_close')).type(ButtonType.Normal).onClick((): void => { this.imageOpen = false })
        Blank()
        Button(this.imageScale === 1 ? '+' : '−').width(48)
          .accessibilityText(localizedText($r('app.string.help_image_zoom')))
          .onClick((): void => { this.imageScale = this.imageScale === 1 ? 2 : 1 })
      }.width('100%').padding(12)
      Scroll() {
        Scroll() {
          Image(this.imageSource).width(this.imageScale === 1 ? '100%' : '200%').objectFit(ImageFit.Contain)
        }.width('100%').scrollable(ScrollDirection.Horizontal)
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor(UiColor.surface)
  }

  @Builder
  private list() {
    Column({ space: 16 }) {
      TextInput({ text: this.query, placeholder: localizedText($r('app.string.help_search')) })
        .fontColor(UiColor.text).placeholderColor(UiColor.secondary).backgroundColor(UiColor.container)
        .width('100%').height(46).onChange((query: string): void => { this.query = query })
      if (this.topic || this.query.trim()) {
        if (this.matchingEntries().length === 0) {
          Text($r('app.string.help_no_results')).fontSize(16).fontColor(UiColor.secondary).padding(18)
        } else {
          SettingsGroup({ title: '' }) {
            ForEach(this.matchingEntries(), (entry: HelpEntry) => {
              SettingsRow({ title: entry.title, detail: this.topic ? entry.summary : this.entryDetail(entry), action: (): void => { this.openArticle(entry.id) } })
            }, (entry: HelpEntry): string => entry.id)
          }
        }
      } else {
        SettingsGroup({ title: localizedText($r('app.string.help_frequent')) }) {
          ForEach(this.entries.filter((entry: HelpEntry): boolean => entry.frequent === true), (entry: HelpEntry) => {
            SettingsRow({ title: entry.title, action: (): void => { this.openArticle(entry.id) } })
          }, (entry: HelpEntry): string => entry.id)
        }
        SettingsGroup({ title: localizedText($r('app.string.help_topics')) }) {
          ForEach(this.topics, (topic: HelpTopic) => {
            SettingsRow({ title: topic.title, action: (): void => {
              PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/Help', params: { topic: topic.id } })
            } })
          }, (topic: HelpTopic): string => topic.id)
        }
      }
    }.width('100%').padding({ left: 16, right: 16, bottom: 28, top: 12 })
  }

  build() {
    Column() {
      Row() {
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ui_back')).width(20).height(20).fillColor(UiColor.text)
        }.width(48).height(48).backgroundColor(Color.Transparent)
          .accessibilityText(localizedText($r('app.string.text_back')))
          .onClick((): void => { this.onBackPress() })
        Text(this.article === 'about' ? localizedText($r('app.string.text_about_org_tasks')) :
          this.topics.find((topic: HelpTopic): boolean => this.topic === topic.id)?.title ??
            localizedText($r('app.string.help_center'))).fontSize(17).fontColor(UiColor.text).layoutWeight(1)
        if (this.sections.length > 1 && !this.failed) {
          Button($r('app.string.help_contents')).type(ButtonType.Normal).backgroundColor(Color.Transparent)
            .fontColor(UiColor.primary).height(48).onClick((): void => { this.showDirectory() })
        }
      }.width('100%').padding({ right: 12 }).border({ width: { bottom: 0.5 }, color: UiColor.divider })
      if (this.loading) {
        LoadingProgress().width(32).height(32).color(UiColor.primary).margin(32)
      } else if (this.failed) {
        Button($r('app.string.help_retry')).margin(24).onClick((): void => { this.load() })
      } else if (this.article) {
        Web({ src: 'about:blank', controller: this.controller }).width('100%').layoutWeight(1)
          .backgroundColor(UiColor.surface).fileAccess(false).blockNetwork(true)
          .javaScriptAccess(true).textZoomRatio(this.zoomRatio)
          .domStorageAccess(false).databaseAccess(false)
          .onPageEnd((): void => { this.pageEnded() })
          .onOverrideUrlLoading((request: WebResourceRequest): boolean => {
            return request.isMainFrame() && this.openLink(request.getRequestUrl())
          })
          .onErrorReceive((event: OnErrorReceiveEvent) => {
            if (event?.request.isMainFrame()) this.failed = true
          })
      } else {
        Scroll() { this.list() }.layoutWeight(1).width('100%').align(Alignment.TopStart)
      }
    }.width('100%').height('100%').backgroundColor(UiColor.surface)
      .bindSheet($$this.directoryOpen, this.directory, { height: '55%', detents: ['55%', '85%'],
        preferType: SheetType.BOTTOM, backgroundColor: UiColor.container, showClose: false })
      .bindContentCover($$this.imageOpen, this.imagePreview)
  }
}
