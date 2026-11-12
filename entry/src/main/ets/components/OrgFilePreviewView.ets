import { webview } from '@kit.ArkWeb'
import { CoreBridgeError, CoreConflictPreviewChanges, CoreConflictPreviewChange, CoreConflictPreviewDiffLine, coreErrorMessage } from '../services/NativeCoreService'
import { OrgContentView } from './OrgContentView'
import { UiColor } from '../ui/Theme'
import { OrgDocumentChapter, OrgDocumentOutline, documentOutlineScript, documentChapterScript, documentExpandScript } from '../ui/OrgDocumentNavigation'

interface PreviewMarkedRange { start: number; end: number; removed: string; added: string }

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

export class OrgFilePreviewNavigation {
  controller: webview.WebviewController = new webview.WebviewController()
  openOutline: () => void = () => {}
  expandAll: (expand: boolean) => void = () => {}
  focusChange: (index: number) => void = () => {}
  focusConflictCard: (id: string) => void = () => {}
  focusFooter: () => void = () => {}
  capturePosition: () => Promise<number> = async (): Promise<number> => 0
  restorePosition: (offset: number) => void = () => {}
  closePanel: () => boolean = () => false
}

// 页面只提供完整快照；加载、冲突选择和最终提交由页面与 Core 负责。
@Component
export struct OrgFilePreviewView {
  @Prop content: string = ''
  @Prop renderedHtml: string = ''
  @Prop displayMode: 'rendered' | 'source' = 'rendered'
  @Prop fileContext: string = ''
  @Prop title: string = ''
  @Prop @Watch('snapshotChanged') revision: string = ''
  @Prop changes: CoreConflictPreviewChanges | undefined = undefined
  @Prop conflictCards: OrgConflictCard[] = []
  conflictCardActivated: ((id: string, action: string) => void) | undefined = undefined
  @Prop showBefore: boolean = false
  @Prop flowContent: boolean = false
  @BuilderParam footer: () => void = this.emptyFooter
  navigation: OrgFilePreviewNavigation = new OrgFilePreviewNavigation()
  ready: () => void = () => {}
  failed: (message: string) => void = () => {}
  nodeActivated: ((index: number) => void) | undefined = undefined
  @State renderReady: boolean = false
  @State outlineVisible: boolean = false
  @State chapters: OrgDocumentChapter[] = []
  @State activeChapter: number = -1
  @State contentMeasureRevision: number = 0
  private outlineRequest: number = 0
  private lifecycle: number = 0
  private active: boolean = true
  private sourceScroller: Scroller = new Scroller()
  private sourceOffsets: Map<number, number> = new Map()
  private lineOffsets: Map<number, number> = new Map()
  private viewportHeight: number = 0
  private contentWidth: number = 0
  private footerOffset: number = 0
  private pendingFlowFocus: boolean = false
  private pendingFlowOffset: number | undefined = undefined

  aboutToAppear() {
    this.active = true
    this.pendingFlowFocus = this.flowContent
    this.navigation.openOutline = (): void => { this.openOutline() }
    this.navigation.expandAll = (expand: boolean): void => { this.expandAll(expand) }
    this.navigation.focusChange = (index: number): void => { this.focusChange(index) }
    this.navigation.focusConflictCard = (id: string): void => { this.focusConflictCard(id) }
    this.navigation.focusFooter = (): void => { this.focusFooter() }
    this.navigation.capturePosition = async (): Promise<number> => {
      if (this.flowContent || this.displayMode === 'source') return this.sourceScroller.currentOffset().yOffset
      if (!this.renderReady) return 0
      try {
        const offset = Number(await this.navigation.controller.runJavaScript('window.scrollY'))
        return Number.isFinite(offset) ? Math.max(0, offset) : 0
      } catch (_) { return 0 }
    }
    this.navigation.restorePosition = (offset: number): void => { this.restorePosition(offset) }
    this.navigation.closePanel = (): boolean => {
      if (!this.outlineVisible) return false
      this.outlineVisible = false
      this.outlineRequest++
      return true
    }
  }
  aboutToDisappear() { this.active = false; this.lifecycle++; this.outlineRequest++; this.renderReady = false; this.outlineVisible = false }
  snapshotChanged() {
    this.lifecycle++; this.renderReady = false; this.outlineRequest++; this.outlineVisible = false
    this.sourceOffsets.clear(); this.lineOffsets.clear(); this.pendingFlowFocus = true; this.pendingFlowOffset = undefined
  }
  async documentReady() {
    if (!this.active) return
    this.renderReady = true
    const revision = this.lifecycle
    try {
      const ranges = (this.changes?.changes ?? []).filter(change => change.area === 'main').map((change: CoreConflictPreviewChange): PreviewMarkedRange => ({
        start: (this.showBefore ? change.before : change.after)?.start.byte_offset ?? 0,
        end: (this.showBefore ? change.before : change.after)?.end.byte_offset ?? 0,
        removed: change.lines.filter(line => line.kind === 'removed').map(line => line.text).join(''),
        added: change.lines.filter(line => line.kind === 'added').map(line => line.text).join('')
      }))
      if (ranges.length > 0) await this.navigation.controller.runJavaScript(`(() => {
        document.querySelectorAll('[data-preview-marker]').forEach(n => n.remove());
        document.querySelectorAll('[data-preview-change]').forEach(n => n.removeAttribute('data-preview-change'));
        const blocks = [...document.querySelectorAll('[data-org-start]')];
        const ranges = ${JSON.stringify(ranges)};
        ranges.forEach((range, index) => {
          const containing = blocks.filter(n => +n.dataset.orgStart <= range.start && +n.dataset.orgEnd >= range.start);
          const target = containing.sort((a,b) => (+a.dataset.orgEnd - +a.dataset.orgStart) - (+b.dataset.orgEnd - +b.dataset.orgStart))[0] || blocks.find(n => +n.dataset.orgStart >= range.start);
          const marker = document.createElement('div');
          marker.dataset.previewMarker = String(index);
          marker.style.cssText = 'margin:12px 0;white-space:pre-wrap;font-size:13px;line-height:1.6;';
          [['− 应用前',range.removed,'#422B33','#FF7592','此处没有内容'],['＋ 应用后',range.added,'#203D33','#65CD7B','此处内容将被删除']].forEach(([label,text,bg,color,empty]) => {
            const block = document.createElement('div');
            block.style.cssText = 'border-left:3px solid '+color+';background:'+bg+';padding:10px;margin:4px 0;';
            const title = document.createElement('div'); title.textContent = label; title.style.color = color;
            const content = document.createElement('div'); content.textContent = text || empty;
            block.append(title,content); marker.append(block);
          });
          if (target) {
            target.dataset.previewChange = String(index);
            for (let p=target; p; p=p.parentElement) if (p.tagName==='DETAILS') p.open=true;
            const summary = target.querySelector(':scope > summary');
            target.insertBefore(marker, summary ? summary.nextSibling : target.firstChild);
          } else {
            const content = document.querySelector('.org-content') || document.body;
            content.append(marker);
          }
        });
        return true;
      })()`)
      await this.injectConflictCards()
      if (this.flowContent) this.contentMeasureRevision++
      if (revision === this.lifecycle && ranges.length > 0) await this.focusChange(0)
      if (revision === this.lifecycle) this.ready()
    } catch (e) { if (revision === this.lifecycle) this.readingError(e as CoreBridgeError) }
  }
  async injectConflictCards() {
    if (this.displayMode !== 'rendered' || this.conflictCards.length === 0) return
    try {
      await this.navigation.controller.runJavaScript(`(() => {
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
    if (!this.renderReady || this.displayMode !== 'rendered') return
    const revision = this.lifecycle
    try {
      const result = await this.navigation.controller.runJavaScript(`(() => {
        const card = [...document.querySelectorAll('[data-conflict-card]')].find(node => node.dataset.conflictCard === ${JSON.stringify(id)});
        if (!card) return -1;
        for (let p = card.parentElement; p; p = p.parentElement) if (p.tagName === 'DETAILS') p.open = true;
        if (!${this.flowContent}) { card.scrollIntoView({block:'start'}); return -1; }
        return (card.getBoundingClientRect().top + window.scrollY) / window.innerWidth;
      })()`)
      if (revision !== this.lifecycle || !this.active) return
      const ratio = Number(result)
      if (this.flowContent && Number.isFinite(ratio) && ratio >= 0 && this.contentWidth > 0) {
        this.pendingFlowOffset = Math.max(0, ratio * this.contentWidth - 16)
        this.pendingFlowFocus = false
        this.contentMeasureRevision++
      }
    } catch (e) { this.readingError(e as CoreBridgeError) }
  }

  async focusChange(index: number) {
    if (this.flowContent && this.displayMode === 'source') {
      const change = this.changes?.changes[index]
      const line = (this.showBefore ? change?.before : change?.after)?.start.line
      const offset = line === undefined ? undefined : this.lineOffsets.get(line - 1)
      if (offset !== undefined) this.sourceScroller.scrollTo({ xOffset: 0, yOffset: offset, animation: false })
      else this.focusFooter()
      return
    }
    if (this.displayMode === 'source') {
      const offset = this.sourceOffsets.get(index)
      if (offset !== undefined) this.sourceScroller.scrollTo({ xOffset: 0, yOffset: offset, animation: false })
      return
    }
    if (!this.renderReady || !Number.isInteger(index) || index < 0) return
    if (this.flowContent) {
      const revision = this.lifecycle
      try {
        const result = await this.navigation.controller.runJavaScript(`(() => {
          const marker = document.querySelector('[data-preview-marker="${index}"]');
          if (!marker) return -1;
          for (let p = marker.parentElement; p; p = p.parentElement) if (p.tagName === 'DETAILS') p.open = true;
          return (marker.getBoundingClientRect().top + window.scrollY) / window.innerWidth;
        })()`)
        if (revision !== this.lifecycle || !this.active) return
        const ratio = Number(result)
        if (Number.isFinite(ratio) && ratio >= 0 && this.contentWidth > 0) {
          this.sourceScroller.scrollTo({ xOffset: 0, yOffset: Math.max(0, ratio * this.contentWidth - this.viewportHeight * 0.2), animation: false })
        } else this.focusFooter()
      } catch (e) { if (revision === this.lifecycle) this.readingError(e as CoreBridgeError) }
      return
    }
    try {
      await this.navigation.controller.runJavaScript(`(() => {
        const marker = document.querySelector('[data-preview-marker="${index}"]');
        if (!marker) return false;
        for (let p = marker.parentElement; p; p = p.parentElement) if (p.tagName === 'DETAILS') p.open = true;
        marker.scrollIntoView({block:'center'}); return true;
      })()`)
    } catch (e) { this.readingError(e as CoreBridgeError) }
  }
  async restorePosition(offset: number) {
    if (!Number.isFinite(offset) || offset < 0 || !this.active) return
    this.pendingFlowFocus = false
    if (this.flowContent && this.displayMode === 'rendered') {
      this.pendingFlowOffset = offset
      this.contentMeasureRevision++
    } else if (this.flowContent || this.displayMode === 'source') {
      this.sourceScroller.scrollTo({ xOffset: 0, yOffset: offset, animation: false })
    } else if (this.renderReady) {
      try { await this.navigation.controller.runJavaScript(`window.scrollTo(0, ${offset})`) }
      catch (e) { this.readingError(e as CoreBridgeError) }
    }
  }
  focusFooter() {
    if (!this.flowContent || !this.active) return
    this.sourceScroller.scrollTo({ xOffset: 0, yOffset: Math.max(0, this.footerOffset - this.viewportHeight * 0.35), animation: false })
  }

  flowMeasured() {
    if (this.pendingFlowOffset !== undefined && this.flowContent && this.renderReady) {
      const offset = this.pendingFlowOffset
      this.pendingFlowOffset = undefined
      this.sourceScroller.scrollTo({ xOffset: 0, yOffset: offset, animation: false })
      return
    }
    if (!this.pendingFlowFocus || !this.flowContent) return
    if (this.displayMode !== 'source' && !this.renderReady) return
    this.pendingFlowFocus = false
    if (this.conflictCards.length > 0) return
    if (this.changes?.changes.length) this.focusChange(0)
    else this.focusFooter()
  }
  async expandAll(expand: boolean) {
    if (!this.renderReady || this.displayMode !== 'rendered' || false) return
    const revision = this.lifecycle
    try {
      await this.navigation.controller.runJavaScript(documentExpandScript(expand))
      if (this.flowContent) this.contentMeasureRevision++
      if (revision === this.lifecycle && this.outlineVisible) await this.openOutline()
    } catch (e) {
      if (revision === this.lifecycle) this.readingError(e as CoreBridgeError)
    }
  }

  readingError(error: CoreBridgeError) {
    try { this.getUIContext().getPromptAction().showToast({ message: `阅读操作失败：${coreErrorMessage(error)}` }) }
    catch (_) { /* 页面退出时无需继续显示提示。 */ }
  }

  async openOutline() {
    if (!this.renderReady || this.displayMode !== 'rendered' || false) return
    const revision = this.lifecycle
    const request = ++this.outlineRequest
    try {
      const result = await this.navigation.controller.runJavaScript(documentOutlineScript())
      if (revision !== this.lifecycle || request !== this.outlineRequest) return
      // 兼容 Web 引擎将字符串结果作为 JSON 字符串再次编码的返回形式。
      const payload = result.startsWith('"') ? JSON.parse(result) as string : result
      const outline = JSON.parse(payload) as OrgDocumentOutline
      this.chapters = outline.chapters
      this.activeChapter = outline.activeIndex
      this.outlineVisible = true
    } catch (e) {
      if (revision === this.lifecycle && request === this.outlineRequest) this.readingError(e as CoreBridgeError)
    }
  }

  async openChapter(chapter: OrgDocumentChapter) {
    if (!this.renderReady || this.displayMode !== 'rendered' || false) return
    if (!Number.isInteger(chapter.index) || chapter.index < 0) return
    const revision = this.lifecycle
    this.outlineRequest++
    try {
      const result = await this.navigation.controller.runJavaScript(this.flowContent ? `(() => {
        const node = document.querySelectorAll('details.heading')[${chapter.index}];
        if (!node) return -1;
        for (let p = node; p; p = p.parentElement) if (p.tagName === 'DETAILS') p.open = true;
        return (node.getBoundingClientRect().top + window.scrollY) / window.innerWidth;
      })()` : documentChapterScript(chapter.index))
      if (revision !== this.lifecycle) return
      if (this.flowContent) {
        const ratio = Number(result)
        if (!Number.isFinite(ratio) || ratio < 0) throw new Error('目录已失效，请重新打开文件')
        this.sourceScroller.scrollTo({ xOffset: 0, yOffset: ratio * this.contentWidth, animation: false })
        this.contentMeasureRevision++
      } else if (result !== 'true') throw new Error('目录已失效，请重新打开文件')
      this.activeChapter = chapter.index
      this.outlineVisible = false
    } catch (e) {
      if (revision === this.lifecycle) this.readingError(e as CoreBridgeError)
    }
  }

  @Builder
  emptyFooter() {}

  @Builder
  flowingDocument() {
    Scroll(this.sourceScroller) {
      Column() {
        if (this.displayMode === 'source') {
          Column() {
            ForEach(this.content.split('\n'), (line: string, index: number) => {
              Text(line || ' ').width('100%').fontSize(14).fontFamily('monospace').fontColor(UiColor.text)
                .copyOption(CopyOptions.LocalDevice)
                .onAreaChange((oldArea: Area, newArea: Area): void => {
                  this.lineOffsets.set(index, Number(newArea.position.y))
                })
            }, (line: string, index: number) => `${this.revision}-${index}`)
          }.width('100%').padding(20)
        } else {
          OrgContentView({ fragment: this.renderedHtml, revision: this.revision, empty: this.content.trim().length === 0,
            controller: this.navigation.controller, embedded: true, flowReading: true, fileReading: true,
            layoutRevision: this.contentMeasureRevision,
            fileContext: this.fileContext, nodeActivated: this.nodeActivated, conflictCardActivated: this.conflictCardActivated,
            ready: (): void => { this.documentReady() }, measured: (): void => { this.flowMeasured() }, failed: this.failed })
            .width('100%')
        }
        Column() { this.footer() }.width('100%')
          .onAreaChange((oldArea: Area, newArea: Area): void => {
            this.footerOffset = Number(newArea.position.y)
            this.flowMeasured()
            if (this.displayMode === 'source') this.ready()
          })
      }.width('100%').constraintSize({ minHeight: this.viewportHeight }).justifyContent(FlexAlign.SpaceBetween)
    }.width('100%').layoutWeight(1).align(Alignment.TopStart)
      .onAreaChange((oldArea: Area, newArea: Area): void => {
        this.viewportHeight = Number(newArea.height)
        this.contentWidth = Number(newArea.width)
      })
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
      if (this.flowContent) {
        this.flowingDocument()
      } else if (this.displayMode === 'source') {
        Scroll(this.sourceScroller) {
          Column({ space: 12 }) {
            if (this.changes) {
              ForEach(this.changes.changes, (change: CoreConflictPreviewChange, index: number) => {
                Column() {
                  Text(`正文变化 ${index + 1}`).fontSize(12).fontColor(UiColor.secondary).width('100%')
                  ForEach(change.lines, (line: CoreConflictPreviewDiffLine, row: number) => {
                    Text(`${line.kind === 'removed' ? '− 应用前' : line.kind === 'added' ? '＋ 应用后' : '上下文'} ${line.beforeLine ?? line.afterLine ?? ''}  ${line.text}`)
                      .fontSize(12).fontFamily('monospace').fontColor(line.kind === 'removed' ? UiColor.error : UiColor.primary)
                      .width('100%').copyOption(CopyOptions.LocalDevice)
                  }, (line: CoreConflictPreviewDiffLine, row: number) => `${index}-${row}`)
                }.width('100%').padding(12).backgroundColor(UiColor.container).borderRadius(8)
                  .onAreaChange((oldArea: Area, newArea: Area): void => {
                    this.sourceOffsets.set(index, Number(newArea.position.y))
                    if (index === 0) this.focusChange(0)
                  })
              }, (change: CoreConflictPreviewChange, index: number) => `${this.revision}-${index}`)
            }
            Text(this.content || '空白 Org 文件').width('100%').fontSize(14).fontFamily('monospace')
              .fontColor(UiColor.text).copyOption(CopyOptions.LocalDevice)
              .onAreaChange((): void => { this.ready() })
          }.width('100%').padding(20)
        }.width('100%').layoutWeight(1).align(Alignment.TopStart)
      } else {
        OrgContentView({ fragment: this.renderedHtml, revision: this.revision, empty: this.content.trim().length === 0,
          controller: this.navigation.controller, fileReading: true, fileContext: this.fileContext,
          nodeActivated: this.nodeActivated, conflictCardActivated: this.conflictCardActivated,
          ready: (): void => { this.documentReady() }, failed: this.failed }).width('100%').layoutWeight(1)
      }
    }.width('100%').height('100%')
      .bindSheet($$this.outlineVisible, this.outlineSheet, {
        height: '60%', detents: ['60%', '85%'], preferType: SheetType.BOTTOM,
        backgroundColor: UiColor.container, showClose: false,
        onDisappear: (): void => { this.outlineRequest++ }
      })
  }
}
