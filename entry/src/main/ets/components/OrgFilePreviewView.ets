import { webview } from '@kit.ArkWeb'
import { CoreBridgeError, CoreConflictPreviewChanges, CoreConflictPreviewChange, CoreConflictPreviewDiffLine, coreErrorMessage } from '../services/NativeCoreService'
import { OrgContentView } from './OrgContentView'
import { UiColor } from '../ui/Theme'
import { OrgDocumentChapter, OrgDocumentOutline, documentOutlineScript, documentChapterScript, documentExpandScript } from '../ui/OrgDocumentNavigation'

interface PreviewMarkedRange { start: number; end: number; kind: string; removed: string }

export class OrgFilePreviewNavigation {
  controller: webview.WebviewController = new webview.WebviewController()
  openOutline: () => void = () => {}
  expandAll: (expand: boolean) => void = () => {}
  focusChange: (index: number) => void = () => {}
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
  @Prop showBefore: boolean = false
  navigation: OrgFilePreviewNavigation = new OrgFilePreviewNavigation()
  ready: () => void = () => {}
  failed: (message: string) => void = () => {}
  nodeActivated: ((index: number) => void) | undefined = undefined
  @State renderReady: boolean = false
  @State outlineVisible: boolean = false
  @State chapters: OrgDocumentChapter[] = []
  @State activeChapter: number = -1
  private outlineRequest: number = 0
  private lifecycle: number = 0
  private active: boolean = true

  aboutToAppear() {
    this.active = true
    this.navigation.openOutline = (): void => { this.openOutline() }
    this.navigation.expandAll = (expand: boolean): void => { this.expandAll(expand) }
    this.navigation.focusChange = (index: number): void => { this.focusChange(index) }
    this.navigation.closePanel = (): boolean => {
      if (!this.outlineVisible) return false
      this.outlineVisible = false
      this.outlineRequest++
      return true
    }
  }
  aboutToDisappear() { this.active = false; this.lifecycle++; this.outlineRequest++; this.renderReady = false; this.outlineVisible = false }
  snapshotChanged() { this.lifecycle++; this.renderReady = false; this.outlineRequest++; this.outlineVisible = false }
  async documentReady() {
    if (!this.active) return
    this.renderReady = true
    this.ready()
    const revision = this.lifecycle
    if (!this.changes) return
    try {
      const ranges = this.changes.changes.filter(change => change.area === 'main').map((change: CoreConflictPreviewChange): PreviewMarkedRange => ({
        start: (this.showBefore ? change.before : change.after)?.start.byte_offset ?? 0,
        end: (this.showBefore ? change.before : change.after)?.end.byte_offset ?? 0,
        kind: change.kind,
        removed: change.lines.filter(line => line.kind === 'removed').map(line => line.text).join('')
      }))
      await this.navigation.controller.runJavaScript(`(() => {
        document.querySelectorAll('[data-preview-marker]').forEach(n => n.remove());
        document.querySelectorAll('[data-preview-change]').forEach(n => n.removeAttribute('data-preview-change'));
        const blocks = [...document.querySelectorAll('[data-org-start]')];
        const ranges = ${JSON.stringify(ranges)};
        ranges.forEach((range, index) => {
          const containing = blocks.filter(n => +n.dataset.orgStart <= range.start && +n.dataset.orgEnd >= range.start);
          const target = containing.sort((a,b) => (+a.dataset.orgEnd - +a.dataset.orgStart) - (+b.dataset.orgEnd - +b.dataset.orgStart))[0] || blocks.find(n => +n.dataset.orgStart >= range.start);
          const marker = document.createElement('div');
          marker.dataset.previewMarker = String(index);
          marker.style.cssText = 'border-left:3px solid #9ad6b5;background:#20382d;padding:12px;margin:12px 0;white-space:pre-wrap;font-size:13px;line-height:1.6;';
          marker.textContent = range.kind === 'delete' ? '将删除\n' + range.removed : '本项合并变化';
          if (target) { target.dataset.previewChange = String(index); target.open = true; target.insertBefore(marker, target.firstChild.nextSibling); }
          else document.body.prepend(marker);
        });
        return true;
      })()`)
      if (revision === this.lifecycle) await this.focusChange(0)
    } catch (e) { if (revision === this.lifecycle) this.readingError(e as CoreBridgeError) }
  }
  async focusChange(index: number) {
    if (!this.renderReady || this.displayMode !== 'rendered') return
    try {
      await this.navigation.controller.runJavaScript(`(() => {
        const marker = document.querySelector('[data-preview-marker="${index}"]');
        if (!marker) return false;
        for (let p = marker.parentElement; p; p = p.parentElement) if (p.tagName === 'DETAILS') p.open = true;
        marker.scrollIntoView({block:'center'}); return true;
      })()`)
    } catch (e) { this.readingError(e as CoreBridgeError) }
  }
  async expandAll(expand: boolean) {
    if (!this.renderReady || this.displayMode !== 'rendered' || false) return
    const revision = this.lifecycle
    try {
      await this.navigation.controller.runJavaScript(documentExpandScript(expand))
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
    const revision = this.lifecycle
    this.outlineRequest++
    try {
      const result = await this.navigation.controller.runJavaScript(documentChapterScript(chapter.index))
      if (revision !== this.lifecycle) return
      if (result !== 'true') throw new Error('目录已失效，请重新打开文件')
      this.activeChapter = chapter.index
      this.outlineVisible = false
    } catch (e) {
      if (revision === this.lifecycle) this.readingError(e as CoreBridgeError)
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
      if (this.displayMode === 'source') {
        Scroll() {
          Column({ space: 12 }) {
            if (this.changes) {
              ForEach(this.changes.changes, (change: CoreConflictPreviewChange, index: number) => {
                Column() {
                  Text(change.area === 'main' ? '正文变化' : '冲突材料变化').fontSize(12).fontColor(UiColor.secondary).width('100%')
                  ForEach(change.lines, (line: CoreConflictPreviewDiffLine, row: number) => {
                    Text(`${line.kind === 'removed' ? '−' : '+'} ${line.beforeLine ?? line.afterLine ?? ''}  ${line.text}`)
                      .fontSize(12).fontFamily('monospace').fontColor(line.kind === 'removed' ? UiColor.error : UiColor.primary)
                      .width('100%').copyOption(CopyOptions.LocalDevice)
                  }, (line: CoreConflictPreviewDiffLine, row: number) => `${index}-${row}`)
                }.width('100%').padding(12).backgroundColor(UiColor.container).borderRadius(8)
              }, (change: CoreConflictPreviewChange, index: number) => `${index}`)
            }
            Text(this.content || '空白 Org 文件').width('100%').fontSize(14).fontFamily('monospace')
              .fontColor(UiColor.text).copyOption(CopyOptions.LocalDevice)
          }.width('100%').padding(20)
        }.width('100%').layoutWeight(1).align(Alignment.TopStart)
      } else {
        OrgContentView({ fragment: this.renderedHtml, empty: this.content.trim().length === 0,
          controller: this.navigation.controller, fileReading: true, fileContext: this.fileContext,
          nodeActivated: this.nodeActivated,
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
