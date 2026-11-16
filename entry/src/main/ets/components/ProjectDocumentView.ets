import { DataSet } from '../services/DataSet'
import { InternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { ProjectReadingSection, visibleProjectTags, projectOutlineSections, projectReadingItems, ProjectReadingItem } from '../ui/ProjectReadingPresentation'
import { OrgFilePreviewNavigation } from './OrgFilePreviewView'
import { ProjectSectionBody } from './ProjectSectionBody'
import { ProjectTaskSection } from './ProjectTaskSection'
import { TaskInlineSession } from '../services/TaskInlineService'
import { taskTagColor } from '../ui/TaskListPresentation'
import { UiColor } from '../ui/Theme'

export class ProjectDocumentNavigation extends OrgFilePreviewNavigation {
  isValidInternalLink: (target: string) => Promise<boolean> = async (): Promise<boolean> => false
  followInternalLink: (target: string) => Promise<void> = async (): Promise<void> => { throw new Error('项目文档尚未载入') }
}

// 原生标题和任务行与安全 HTML 正文共用一个滚动容器。
@Component
export struct ProjectDocumentView {
  dataSet: DataSet | undefined = undefined
  private taskDataSet(): DataSet {
    if (!this.dataSet) throw new Error('项目文件数据集尚未载入')
    return this.dataSet
  }

  @Prop @Watch('updateDocument') sections: ProjectReadingSection[] = []
  @Prop @Watch('updateDocument') matchedIds: string[] = []
  @Prop @Watch('updateDocument') tagFiltered: boolean = false
  @State readingItems: ProjectReadingItem[] = []
  @StorageLink('taskInlineActive') @Watch('updateDocument') inlineActive: string = ''
  @Prop fileTags: string[] = []
  @Prop specialTags: string[] = []
  @Prop @Watch('snapshotChanged') revision: string = ''
  @Prop readingState: string = ''
  @Prop @Watch('visibilityChanged') showing: boolean = true
  navigation: ProjectDocumentNavigation = new ProjectDocumentNavigation()
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  ready: () => void = () => {}
  scrolled: (offset: number) => void = () => {}
  @State outlineVisible: boolean = false
  @State outlineItems: ProjectReadingSection[] = []
  private stopTasks: (() => void) | undefined = undefined

  linkSection(target: string): ProjectReadingSection | undefined {
    let priority = Infinity
    let found: ProjectReadingSection | undefined = undefined
    for (const section of this.sections) {
      for (const destination of section.linkTargets) {
        if (this.readingItems.length > 0 && !this.readingItems.some(item => item.section.key === section.key)) continue
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
    this.stopTasks = this.dataSet?.subscribe((): void => { this.updateDocument() })
    this.updateDocument()
    this.navigation.isValidInternalLink = async (target: string): Promise<boolean> =>
      this.active && this.showing && this.linkSection(target) !== undefined
    this.navigation.followInternalLink = async (target: string): Promise<void> => {
      const section = this.linkSection(target)
      if (!section || !this.active || !this.showing) throw new Error('内部链接目标不存在或项目文档已隐藏')
      if (!await this.openChapter(section)) throw new Error('无法定位内部链接，请先完成当前编辑后重试')
    }
    try { this.pendingOffset = (JSON.parse(this.readingState) as Record<string, number>).scroll } catch (_) {}
    this.navigation.captureReadingState = async (): Promise<string> => JSON.stringify({ scroll: this.scroller.currentOffset().yOffset })
    this.navigation.openOutline = (): void => { this.updateOutline(); this.outlineVisible = true }
    this.navigation.closePanel = (): boolean => {
      if (!this.outlineVisible) return false
      this.outlineVisible = false
      return true
    }
  }

  aboutToDisappear() { this.stopTasks?.(); this.stopTasks = undefined; this.active = false; this.outlineVisible = false }

  visibilityChanged() {
    if (!this.showing) return
    try { this.pendingOffset = (JSON.parse(this.readingState) as Record<string, number>).scroll } catch (_) {}
  }

  snapshotChanged() {
    this.offsets.clear()
    this.outlineVisible = false
    let offset: number = 0
    try { offset = (JSON.parse(this.readingState) as Record<string, number>).scroll ?? 0 } catch (_) {}
    this.pendingOffset = offset
    this.scroller.scrollTo({ xOffset: 0, yOffset: offset, animation: false })
    this.ready()
  }

  async openChapter(section: ProjectReadingSection): Promise<boolean> {
    const revision = this.revision
    if (!await TaskInlineSession.end(false) || !this.active || !this.showing || revision !== this.revision) return false
    if (this.readingItems.length > 0 && !this.readingItems.some(item => item.section.key === section.key)) return false
    const offset = this.offsets.get(section.key)
    if (offset === undefined) return false
    this.outlineVisible = false
    this.scroller.scrollTo({ xOffset: 0, yOffset: Math.max(0, offset - 12), animation: false })
    return true
  }

  updateOutline(): void {
    this.outlineItems = projectOutlineSections(this.readingItems.map(item => item.section).map((section: ProjectReadingSection): ProjectReadingSection => ({
      key: section.key, node: section.node ? this.dataSet?.getTask(section.key) ?? section.node : null,
      html: section.html, blocks: section.blocks, linkTargets: section.linkTargets
    })))
  }

  updateDocument(): void {
    if (TaskInlineSession.active()) return
    const current = this.sections.map((section: ProjectReadingSection): ProjectReadingSection => ({
      key: section.key, node: section.node ? this.dataSet?.getTask(section.key) ?? section.node : null,
      html: section.html, blocks: section.blocks, linkTargets: section.linkTargets
    }))
    this.readingItems = projectReadingItems(current, this.tagFiltered ? this.matchedIds : null)
    if (this.outlineVisible) this.updateOutline()
  }

  @Builder
  outlineSheet() {
    Column({ space: 12 }) {
      Text('文档目录').fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text).width('100%')
      if (this.outlineItems.length === 0) {
        Text('本文没有章节标题').fontSize(14).fontColor(UiColor.secondary).padding(24)
      }
      List() {
        ForEach(this.outlineItems, (section: ProjectReadingSection) => {
          if (section.node) {
            ListItem() {
              Text(section.node.heading).fontSize(15).fontColor(UiColor.text).width('100%')
                .padding({ left: Math.min(section.node.level - 1, 4) * 8, top: 12, bottom: 12 })
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
        ForEach(this.readingItems, (item: ProjectReadingItem) => {
          Column({ space: item.section.node ? 0 : 12 }) {
            if (!item.section.node && item.section.blocks.length > 0) {
              Text('导言').fontSize(12).fontColor(UiColor.projectLabel).width('100%')
            }
            if (item.section.node) {
              ProjectTaskSection({ dataSet: this.taskDataSet(), taskId: item.section.key, hasChildren: item.hasChildren, contextOnly: item.contextOnly,
                internalLinkProcessor: this.internalLinkProcessor, specialTags: this.specialTags, scrollHost: this.scroller }).width('100%')
            } else if (item.section.blocks.length > 0) {
              ProjectSectionBody({ internalLinkProcessor: this.internalLinkProcessor, task: null, blocks: item.section.blocks,
                contentBackground: UiColor.projectBlock }).width('100%')
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
            .padding({ left: item.section.node ? 0 : (item.section.blocks.length > 0 ? 16 : 0),
              right: !item.section.node && item.section.blocks.length > 0 ? 16 : 0,
              top: !item.section.node && item.section.blocks.length > 0 ? 16 : 0, bottom: !item.section.node && item.section.blocks.length > 0 ? 16 : 0 })
            .backgroundColor(item.section.node ? Color.Transparent : UiColor.projectBlock).borderRadius(item.section.node ? 0 : 12)
            .onAreaChange((_old: Area, area: Area): void => { this.offsets.set(item.section.key, Number(area.position.y)) })
        }, (item: ProjectReadingItem) => `${this.revision}:${item.section.key}:${item.hasChildren}:${item.contextOnly}`)
        if (this.tagFiltered && this.readingItems.every(item => item.section.node === null)) {
          Text('没有匹配标签的内容').fontSize(14).fontColor(UiColor.secondary).padding({ top: 48, bottom: 48 })
        }
        if (this.sections.every((section: ProjectReadingSection) => section.node === null && section.blocks.length === 0)) {
          Text('项目还没有内容').fontSize(14).fontColor(UiColor.secondary).padding({ top: 64, bottom: 64 })
        }
      }.width('100%').padding({ left: 12, right: 12, top: 4, bottom: 48 })
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
