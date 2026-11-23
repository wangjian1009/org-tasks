import { webview } from '@kit.ArkWeb'
import { CoreBridgeError, coreErrorMessage } from '../services/NativeCoreService'
import { OrgContentView } from './OrgContentView'
import { UiColor } from '../ui/Theme'
import { OrgDocumentChapter, OrgDocumentOutline, documentOutlineScript, documentChapterScript, documentExpandScript } from '../ui/OrgDocumentNavigation'

export interface OrgConflictCard {
  id: string
  title: string
  kind: string
  kindLabel: string
  applyLabel: string
  content: string
  anchorStart: number
  atTarget: boolean
  html: string
  available: boolean
}

export class OrgFileConflictNavigation {
  openOutline: () => void = () => {}
  focusConflictCard: (id: string) => void = () => {}
  capturePosition: () => Promise<number> = async () => 0
  restorePosition: (offset: number) => void = () => {}
  closePanel: () => boolean = () => false
}

@Component
export struct OrgFileConflictView {
  @Prop renderedHtml: string = ''
  @Prop title: string = ''
  @Prop @Watch('snapshotChanged') revision: string = ''
  @Prop conflictCards: OrgConflictCard[] = []
  navigation: OrgFileConflictNavigation = new OrgFileConflictNavigation()
  conflictCardActivated: ((id: string, action: string) => void) | undefined = undefined
  ready: () => void = () => {}
  failed: (message: string) => void = () => {}
  @State private outlineVisible: boolean = false
  @State private chapters: OrgDocumentChapter[] = []
  @State private activeChapter: number = -1
  private controller: webview.WebviewController = new webview.WebviewController()
  private outlineRequest: number = 0
  private lifecycle: number = 0
  private active: boolean = true
  private renderReady: boolean = false

  aboutToAppear() {
    this.active = true
    this.navigation.openOutline = (): void => { this.openOutline() }
    this.navigation.focusConflictCard = (id: string): void => { this.focusConflictCard(id) }
    this.navigation.capturePosition = async (): Promise<number> => {
      if (!this.renderReady) return 0
      try {
        const offset = Number(await this.controller.runJavaScript('window.scrollY'))
        return Number.isFinite(offset) ? Math.max(0, offset) : 0
      } catch (_) { return 0 }
    }
    this.navigation.restorePosition = (offset: number): void => {
      if (this.renderReady) this.controller.runJavaScript(`window.scrollTo(0, ${offset})`)
        .catch((error: CoreBridgeError): void => { this.readingError(error) })
    }
    this.navigation.closePanel = (): boolean => {
      if (!this.outlineVisible) return false
      this.outlineVisible = false
      this.outlineRequest++
      return true
    }
  }

  aboutToDisappear() { this.active = false; this.snapshotChanged() }

  snapshotChanged() {
    this.lifecycle++
    this.outlineRequest++
    this.renderReady = false
    this.outlineVisible = false
  }

  async documentReady() {
    const version = this.lifecycle
    try {
      await this.injectConflictCards()
      if (this.active && version === this.lifecycle) {
        this.renderReady = true
        this.ready()
      }
    } catch (error) {
      if (this.active && version === this.lifecycle) this.failed(`读取冲突文档失败：${coreErrorMessage(error as CoreBridgeError)}`)
    }
  }

  async injectConflictCards() {
    if (this.conflictCards.length === 0) return
    try {
      await this.controller.runJavaScript(`(() => {
      document.querySelectorAll('[data-conflict-card]').forEach(n => n.remove());
      const cards = ${JSON.stringify(this.conflictCards)};
      const headings = [...document.querySelectorAll('details.heading')];
      const anchorOf = card => headings.find(node => +node.dataset.orgStart === card.anchorStart);
      const groups = new Map();
      cards.forEach(card => {
        const anchor = anchorOf(card);
        const box = document.createElement('aside'); box.dataset.conflictCard = card.id;
        box.className = 'conflict-card conflict-' + card.kind;
        const header = document.createElement('div'); header.className = 'conflict-card-header';
        const badge = document.createElement('span'); badge.className = 'conflict-card-badge'; badge.textContent = card.kindLabel || '冲突';
        const title = document.createElement('strong'); title.className = 'conflict-card-title'; title.textContent = card.title || '未命名节点';
        header.append(badge, title); box.append(header);
        const body = document.createElement('div'); body.className = 'conflict-card-body';
        body.innerHTML = card.html;
        const candidateRoot = body.querySelector('details.heading');
        const candidateSummary = candidateRoot?.querySelector(':scope > summary');
        const candidateTitle = candidateSummary?.querySelector('.heading-title');
        if (candidateTitle) title.innerHTML = candidateTitle.innerHTML;
        if (candidateRoot && candidateSummary) {
          candidateSummary.remove(); candidateRoot.replaceWith(...candidateRoot.childNodes);
        }
        body.querySelectorAll('details.heading').forEach(node => node.classList.remove('heading'));
        body.querySelectorAll('[data-org-start]').forEach(node => { node.removeAttribute('data-org-start'); node.removeAttribute('data-org-end'); node.removeAttribute('id'); });
        if (!body.textContent.trim()) body.textContent = card.content || '候选材料不可用，可丢弃此冲突';
        box.append(body);
        const actions = document.createElement('div'); actions.className = 'conflict-card-actions';
        if (card.available) {
          const apply = document.createElement('button'); apply.type = 'button'; apply.dataset.conflictAction = 'apply'; apply.dataset.conflictId = card.id; apply.textContent = card.applyLabel || '应用'; actions.append(apply);
        }
        const discard = document.createElement('button'); discard.type = 'button'; discard.dataset.conflictAction = 'discard'; discard.dataset.conflictId = card.id; discard.textContent = '丢弃'; actions.append(discard); box.append(actions);
        const key = String(card.anchorStart) + ':' + String(card.atTarget);
        let group = groups.get(key);
        if (!group) {
          group = document.createElement('div'); groups.set(key, group);
          const hiddenAncestor = anchor?.closest('details.heading[hidden]');
          if (hiddenAncestor) hiddenAncestor.after(group);
          else if (anchor && card.atTarget) { anchor.before(group); anchor.hidden = true; }
          else if (anchor) {
            const child = anchor.querySelector(':scope > details.heading'); anchor.insertBefore(group, child);
          } else document.body.appendChild(group);
        }
        group.appendChild(box);
      });
      return true;
      })()`)
    } catch (error) {
      throw error instanceof Error ? error : new Error(String(error))
    }
  }

  async focusConflictCard(id: string) {
    if (!this.renderReady) return
    try {
      await this.controller.runJavaScript(`(() => {
        const card = [...document.querySelectorAll('[data-conflict-card]')].find(node => node.dataset.conflictCard === ${JSON.stringify(id)});
        if (!card) return;
        for (let parent = card.parentElement; parent; parent = parent.parentElement) if (parent.tagName === 'DETAILS') parent.open = true;
        card.scrollIntoView({block:'start'});
      })()`)
    } catch (error) { this.readingError(error as CoreBridgeError) }
  }

  async expandAll(expand: boolean) {
    if (!this.renderReady) return
    const version = this.lifecycle
    try {
      await this.controller.runJavaScript(documentExpandScript(expand))
      if (version === this.lifecycle && this.outlineVisible) await this.openOutline()
    } catch (error) {
      if (version === this.lifecycle) this.readingError(error as CoreBridgeError)
    }
  }

  private readingError(error: CoreBridgeError) {
    if (!this.active) return
    try { this.getUIContext().getPromptAction().showToast({ message: `阅读操作失败：${coreErrorMessage(error)}` }) }
    catch (_) { /* 页面销毁时无需显示提示。 */ }
  }

  async openOutline() {
    if (!this.renderReady) return
    const request = ++this.outlineRequest
    try {
      const result = await this.controller.runJavaScript(documentOutlineScript())
      if (request !== this.outlineRequest) return
      const outline = JSON.parse(result.startsWith('"') ? JSON.parse(result) as string : result) as OrgDocumentOutline
      this.chapters = outline.chapters
      this.activeChapter = outline.activeIndex
      this.outlineVisible = true
    } catch (error) {
      if (request === this.outlineRequest) this.readingError(error as CoreBridgeError)
    }
  }

  async openChapter(chapter: OrgDocumentChapter) {
    if (!this.renderReady || !Number.isInteger(chapter.index) || chapter.index < 0) return
    const request = ++this.outlineRequest
    try {
      const result = await this.controller.runJavaScript(documentChapterScript(chapter.index))
      if (request !== this.outlineRequest) return
      if (result !== 'true') throw new Error('目录已失效，请重新打开文件')
      this.activeChapter = chapter.index
      this.outlineVisible = false
    } catch (error) {
      if (request === this.outlineRequest) this.readingError(error as CoreBridgeError)
    }
  }

  @Builder
  outlineSheet() {
    Column() {
      Row() {
        Text('文档目录').fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text).layoutWeight(1)
        Button('全部展开').fontSize(12).fontColor(UiColor.primary).backgroundColor(Color.Transparent).height(44)
          .onClick((): void => { this.expandAll(true) })
        Button('全部收起').fontSize(12).fontColor(UiColor.primary).backgroundColor(Color.Transparent).height(44)
          .onClick((): void => { this.expandAll(false) })
      }.width('100%')
      Text(`${this.title} · ${this.chapters.length} 个章节`).fontSize(12).fontColor(UiColor.secondary)
        .width('100%').margin({ top: 2, bottom: 16 })
      if (this.chapters.length === 0) {
        Text('本文没有章节标题').fontSize(14).fontColor(UiColor.secondary).padding({ top: 24, bottom: 32 })
      } else {
        List({ space: 4, initialIndex: Math.max(0, this.activeChapter) }) {
          ForEach(this.chapters, (chapter: OrgDocumentChapter) => {
            ListItem() {
              Row() {
                Row().width(2).height(24).backgroundColor(chapter.index === this.activeChapter ? UiColor.primary : Color.Transparent)
                Text(chapter.title).fontSize(chapter.level === 1 ? 15 : 14)
                  .fontColor(chapter.index === this.activeChapter ? UiColor.primary : chapter.level === 1 ? UiColor.text : UiColor.secondary)
                  .fontWeight(chapter.level === 1 ? FontWeight.Medium : FontWeight.Normal)
                  .padding({ left: 12 + Math.min(chapter.level - 1, 4) * 16, right: 12, top: 12, bottom: 12 }).layoutWeight(1)
              }.width('100%').constraintSize({ minHeight: 48 }).borderRadius(8)
                .backgroundColor(chapter.index === this.activeChapter ? UiColor.selected : Color.Transparent)
                .accessibilityText(`${chapter.level} 级标题，${chapter.title}${chapter.index === this.activeChapter ? '，当前章节' : ''}`)
                .onClick((): void => { this.openChapter(chapter) })
            }
          }, (chapter: OrgDocumentChapter) => `${chapter.index}`)
        }.width('100%').layoutWeight(1)
      }
    }.width('100%').height('100%').padding({ left: 20, right: 20, top: 8, bottom: 24 })
      .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      OrgContentView({ fragment: this.renderedHtml, revision: this.revision, empty: !this.renderedHtml,
        controller: this.controller, fileReading: true, conflictCardActivated: this.conflictCardActivated,
        ready: (): void => { this.documentReady() }, failed: this.failed }).width('100%').layoutWeight(1)
    }.width('100%').height('100%')
      .bindSheet($$this.outlineVisible, this.outlineSheet, {
        height: '60%', detents: ['60%', '85%'], preferType: SheetType.BOTTOM,
        backgroundColor: UiColor.container, showClose: false,
        onDisappear: (): void => { this.outlineRequest++ }
      })
  }
}
