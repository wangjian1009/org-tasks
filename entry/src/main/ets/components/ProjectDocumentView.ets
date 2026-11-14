import { InternalLinkProcessor, CallbackInternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { ProjectReadingSection, visibleProjectTags, projectOutlineSections } from '../ui/ProjectReadingPresentation'
import { OrgFilePreviewNavigation } from './OrgFilePreviewView'
import { TaskDocumentContent } from './editors/TaskDocumentContent'
import { OrgHeadingView } from './OrgHeadingView'
import { TaskEditor } from './editors/TaskEditor'
import { TaskInlineSession } from '../services/TaskInlineService'
import { TaskDateDisplay, RegionAreaPolicy, taskTagColor } from '../ui/TaskListPresentation'
import { UiColor } from '../ui/Theme'

// 原生标题和任务行与安全 HTML 正文共用一个滚动容器。
@Component
export struct ProjectDocumentView {
  @Prop sections: ProjectReadingSection[] = []
  @Prop fileTags: string[] = []
  @Prop specialTags: string[] = []
  @Prop @Watch('snapshotChanged') revision: string = ''
  @Prop readingState: string = ''
  @Prop @Watch('visibilityChanged') showing: boolean = true
  navigation: OrgFilePreviewNavigation = new OrgFilePreviewNavigation()
  ready: () => void = () => {}
  scrolled: (offset: number) => void = () => {}
  @State outlineVisible: boolean = false
  private internalLinks: InternalLinkProcessor = new CallbackInternalLinkProcessor(
    async (target: string): Promise<boolean> => this.active && this.linkSection(target) !== undefined,
    async (target: string): Promise<void> => {
      const section = this.linkSection(target)
      if (!section || !this.active) throw new Error('内部链接目标不存在')
      if (!await this.openChapter(section)) throw new Error('无法定位内部链接，请先完成当前编辑后重试')
    }
  )

  linkSection(target: string): ProjectReadingSection | undefined {
    let priority = Infinity
    let found: ProjectReadingSection | undefined = undefined
    for (const section of this.sections) {
      for (const destination of section.linkTargets) {
        if (destination.target === target && destination.priority < priority) { found = section; priority = destination.priority }
      }
    }
    return found
  }

  private scroller: Scroller = new Scroller()
  private offsets: Map<string, number> = new Map()
  private active: boolean = false
  private pendingOffset: number | undefined = undefined

  aboutToAppear() {
    this.active = true
    try { this.pendingOffset = (JSON.parse(this.readingState) as Record<string, number>).scroll } catch (_) {}
    this.navigation.captureReadingState = async (): Promise<string> => JSON.stringify({ scroll: this.scroller.currentOffset().yOffset })
    this.navigation.openOutline = (): void => { this.outlineVisible = true }
    this.navigation.closePanel = (): boolean => {
      if (!this.outlineVisible) return false
      this.outlineVisible = false
      return true
    }
  }

  aboutToDisappear() { this.active = false; this.outlineVisible = false }

  visibilityChanged() {
    if (!this.showing) return
    try { this.pendingOffset = (JSON.parse(this.readingState) as Record<string, number>).scroll } catch (_) {}
  }

  snapshotChanged() {
    this.offsets.clear()
    this.outlineVisible = false
    this.pendingOffset = 0
    this.scroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false })
    this.ready()
  }

  async openChapter(section: ProjectReadingSection): Promise<boolean> {
    const revision = this.revision
    if (!await TaskInlineSession.end(false) || !this.active || revision !== this.revision) return false
    const offset = this.offsets.get(section.key)
    if (offset === undefined) return false
    this.outlineVisible = false
    this.scroller.scrollTo({ xOffset: 0, yOffset: Math.max(0, offset - 12), animation: false })
    return true
  }

  @Builder
  bodyGuide(section: ProjectReadingSection) {
    if (section.node) {
      Column() {
        Rect().width(1).layoutWeight(1).fill(UiColor.divider)
      }.width(1).height('100%').padding({ top: 3, bottom: 3 }).hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')
    }
  }

  @Builder
  outlineSheet() {
    Column({ space: 12 }) {
      Text('文档目录').fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text).width('100%')
      if (projectOutlineSections(this.sections).length === 0) {
        Text('本文没有章节标题').fontSize(14).fontColor(UiColor.secondary).padding(24)
      }
      List() {
        ForEach(projectOutlineSections(this.sections), (section: ProjectReadingSection) => {
          if (section.node) {
            ListItem() {
              Text(section.node.heading).fontSize(15).fontColor(UiColor.text).width('100%')
                .padding({ left: Math.min(section.node.level - 1, 4) * 12, top: 12, bottom: 12 })
                .constraintSize({ minHeight: 48 }).onClick((): void => { this.openChapter(section) })
            }
          }
        }, (section: ProjectReadingSection) => section.key)
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%').padding(24)
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        if (visibleProjectTags(this.fileTags, this.specialTags).length > 0) {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(visibleProjectTags(this.fileTags, this.specialTags), (tag: string) => {
              Text(tag).fontSize(12).fontColor(UiColor.text).wordBreak(WordBreak.BREAK_ALL)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(10)
                .backgroundColor(taskTagColor(tag)).margin({ right: 6, bottom: 6 })
            }, (tag: string) => tag)
          }.width('100%').padding({ top: 8, bottom: 12 })
        }
        ForEach(this.sections, (section: ProjectReadingSection) => {
          Column() {
            if (section.node) {
              if (section.node.state) {
                TaskEditor({ internalLinkProcessor: this.internalLinks, task: section.node, documentMode: true, contentHidden: true, hiddenTags: this.specialTags,
                  instanceKey: `project:${section.node.id}`, dateDisplay: TaskDateDisplay.Schedule,
                  regionAreaPolicy: RegionAreaPolicy.None, scrollHost: this.scroller, scrollHostId: 'project_document_scroll' })
                  .width('100%')
              } else {
                OrgHeadingView({ internalLinkProcessor: this.internalLinks, node: section.node, specialTags: this.specialTags }).width('100%')
              }
            }
            if (section.blocks.length > 0) {
              TaskDocumentContent({ internalLinkProcessor: this.internalLinks, task: section.node, blocks: section.blocks, readonly: section.node === null,
                projectReading: true }).width('100%')
                .padding({ left: section.node ? (section.node.state ? 28 : 12) : 0 })
                .overlay(this.bodyGuide(section), { align: Alignment.TopStart, offset: { x: section.node?.state ? 8 : 0 } })
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
            .padding({ left: section.node ? Math.min(section.node.fullPath.titles.length - 1, 2) * 12 : 0 })
            .onAreaChange((_old: Area, area: Area): void => { this.offsets.set(section.key, Number(area.position.y)) })
        }, (section: ProjectReadingSection) => `${this.revision}:${section.key}`)
        if (this.sections.every((section: ProjectReadingSection) => section.node === null && section.blocks.length === 0)) {
          Text('项目还没有内容').fontSize(14).fontColor(UiColor.secondary).padding({ top: 64, bottom: 64 })
        }
      }.width('100%').constraintSize({ maxWidth: 740 }).padding({ left: 20, right: 20, top: 12, bottom: 48 })
    }.id('project_document_scroll').width('100%').height('100%').align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .onAppear((): void => { this.ready() })
      .onDidScroll((): void => { if (this.showing) this.scrolled(this.scroller.currentOffset().yOffset) })
      .onAreaChange((_old: Area, area: Area): void => {
        if (this.showing && Number(area.height) > 0 && this.pendingOffset !== undefined) {
          this.scroller.scrollTo({ xOffset: 0, yOffset: this.pendingOffset, animation: false })
          this.pendingOffset = undefined
        }
      })
      .bindSheet($$this.outlineVisible, this.outlineSheet(), {
        height: '70%', detents: ['70%', '95%'], preferType: SheetType.BOTTOM,
        backgroundColor: UiColor.surface, showClose: true
      })
  }
}
