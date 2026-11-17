import { DataSet } from '../services/DataSet'
import { InternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { ProjectReadingSection, projectOutlineSections, projectReadingItems, ProjectReadingItem } from '../ui/ProjectReadingPresentation'
import { OrgFilePreviewNavigation } from './OrgFilePreviewView'
import { ProjectSectionBody } from './ProjectSectionBody'
import { ProjectTaskSection } from './ProjectTaskSection'
import { TaskInlineSession } from '../services/TaskInlineService'
import { UiColor } from '../ui/Theme'
import { TitleText } from './TitleText'
import { priorityColor, priorityBackground, priorityLabel } from '../ui/TaskPriorityPresentation'
import { ProjectFileHeader, ProjectHeaderNavigation } from './ProjectFileHeader'
import { CoreFileHeaderEntry, CoreFileHeaderValueChange } from '../services/NativeCoreService'

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
  @State visibleKeys: string[] = []
  @State contextKeys: string[] = []
  @State parentKeys: string[] = []
  @StorageLink('taskInlineActive') @Watch('updateDocument') inlineActive: string = ''
  @Prop headerEntries: CoreFileHeaderEntry[] = []
  @Prop headerVersion: string = ''
  @Prop categoryOptions: string[] = []
  beforeHeaderEdit: () => Promise<boolean> = async () => true
  saveHeader: (changes: CoreFileHeaderValueChange[], version: string) => Promise<void> = async () => {}

  @Prop tagOptions: string[] = []
  @Prop selectedTags: string[] = []
  @Prop category: string = ''
  @Prop selectedCategory: string = ''
  toggleTag: (tag: string) => void = () => {}
  toggleCategory: () => void = () => {}
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
  private headerNavigation: ProjectHeaderNavigation = new ProjectHeaderNavigation()
  private stopTasks: (() => void) | undefined = undefined

  linkSection(target: string): ProjectReadingSection | undefined {
    let priority = Infinity
    let found: ProjectReadingSection | undefined = undefined
    for (const section of this.sections) {
      for (const destination of section.linkTargets) {
        if (this.readingItems.length > 0 && !this.visibleKeys.includes(section.key)) continue
        if (destination.target === target && destination.priority < priority) { found = section; priority = destination.priority }
      }
    }
    return found
  }

  private scroller: Scroller = new Scroller()
  private offsets: Map<string, number> = new Map()
  private active: boolean = false
  private pendingOffset: number | undefined = undefined
  private headerHeight: number = 0
  private contentHeight: number = 0
  private viewportHeight: number = 0
  private initialOffsetApplied: boolean = false

  private readOffset(): number | undefined {
    try {
      const value = (JSON.parse(this.readingState) as Record<string, number>).scroll
      return typeof value === 'number' && Number.isFinite(value) ? Math.max(0, value) : undefined
    } catch (_) { return undefined }
  }

  private scheduleInitialOffset(): void {
    if (this.initialOffsetApplied || (this.pendingOffset !== undefined && this.pendingOffset !== 0) || this.headerHeight <= 0 || this.viewportHeight <= 0 || this.contentHeight <= 0) return
    const offset = Math.min(this.headerHeight, Math.max(0, this.contentHeight - this.viewportHeight))
    this.pendingOffset = offset
    if (this.showing && offset > 0) {
      this.scroller.scrollTo({ xOffset: 0, yOffset: offset, animation: false })
      this.pendingOffset = undefined
      this.initialOffsetApplied = true
    } else if (offset === 0) {
      this.pendingOffset = undefined
      this.initialOffsetApplied = true
    }
  }

  aboutToAppear() {
    this.active = true
    this.initialOffsetApplied = this.readOffset() !== undefined
    this.stopTasks = this.dataSet?.subscribe((): void => { this.updateDocument() })
    this.updateDocument()
    this.navigation.isValidInternalLink = async (target: string): Promise<boolean> =>
      this.active && this.showing && this.linkSection(target) !== undefined
    this.navigation.followInternalLink = async (target: string): Promise<void> => {
      const section = this.linkSection(target)
      if (!section || !this.active || !this.showing) throw new Error('内部链接目标不存在或项目文档已隐藏')
      if (!await this.openChapter(section)) throw new Error('无法定位内部链接，请先完成当前编辑后重试')
    }
    this.pendingOffset = this.readOffset()
    this.navigation.captureReadingState = async (): Promise<string> => JSON.stringify({ scroll: this.scroller.currentOffset().yOffset })
    this.navigation.openOutline = (): void => { this.updateOutline(); this.outlineVisible = true }
    this.navigation.closePanel = (): boolean => {
      if (this.headerNavigation.close()) return true
      if (!this.outlineVisible) return false
      this.outlineVisible = false
      return true
    }
  }

  aboutToDisappear() { this.stopTasks?.(); this.stopTasks = undefined; this.active = false; this.outlineVisible = false }

  visibilityChanged() {
    if (!this.showing) return
    this.pendingOffset = this.readOffset()
    this.initialOffsetApplied = this.pendingOffset !== undefined
  }

  snapshotChanged() {
    this.offsets.clear()
    this.outlineVisible = false
    const offset = this.readOffset()
    this.initialOffsetApplied = offset !== undefined
    this.pendingOffset = offset ?? 0
    this.scroller.scrollTo({ xOffset: 0, yOffset: offset ?? 0, animation: false })
    if (offset === undefined) this.scheduleInitialOffset()
    this.ready()
  }

  async openChapter(section: ProjectReadingSection): Promise<boolean> {
    const revision = this.revision
    if (!await TaskInlineSession.end(false) || !this.active || !this.showing || revision !== this.revision) return false
    if (this.readingItems.length > 0 && !this.visibleKeys.includes(section.key)) return false
    const offset = this.offsets.get(section.key)
    if (offset === undefined) return false
    this.outlineVisible = false
    this.scroller.scrollTo({ xOffset: 0, yOffset: Math.max(0, offset - 12), animation: false })
    return true
  }

  updateOutline(): void {
    this.outlineItems = projectOutlineSections(this.readingItems.filter(item => item.visible).map(item => item.section).map((section: ProjectReadingSection): ProjectReadingSection => ({
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
    this.visibleKeys = this.readingItems.filter(item => item.visible).map(item => item.section.key)
    this.contextKeys = this.readingItems.filter(item => item.contextOnly).map(item => item.section.key)
    this.parentKeys = this.readingItems.filter(item => item.hasChildren).map(item => item.section.key)
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
              Column({ space: 0 }) {
                if (section.node.level === 1) { Divider().color(UiColor.divider).strokeWidth(1) }
                Row({ space: 8 }) {
                  if (section.node.level === 1) {
                    Image($r('app.media.ui_document_outline')).width(18).height(18).fillColor(UiColor.secondary)
                      .accessibilityLevel('no')
                  } else {
                    Text('›').fontSize(18).fontColor(UiColor.secondary).width(12).accessibilityLevel('no')
                  }
                  if (section.node.priority) {
                    Text(section.node.priority.name).fontSize(12).fontWeight(FontWeight.Medium)
                      .fontColor(priorityColor(section.node.priority.category)).textAlign(TextAlign.Center)
                      .constraintSize({ minWidth: 24, minHeight: 22 }).padding({ left: 5, right: 5, top: 2, bottom: 2 })
                      .backgroundColor(priorityBackground(section.node.priority.category)).borderRadius(6).flexShrink(0)
                      .accessibilityText(priorityLabel(section.node.priority))
                  }
                  TitleText({ text: section.node.heading, parts: section.node.headingParts,
                    textSize: section.node.level === 1 ? 18 : section.node.level === 2 ? 16 : 14,
                    weight: section.node.level === 1 ? FontWeight.Bold : section.node.level === 2 ? FontWeight.Medium : FontWeight.Normal,
                    openLinks: false }).layoutWeight(1)
                }.width('100%').alignItems(VerticalAlign.Center)
                  .padding({ left: Math.min(section.node.level - 1, 4) * 20, top: 12, bottom: 12 })
                  .constraintSize({ minHeight: section.node.level === 1 ? 56 : 48 })
              }.width('100%').margin({ top: section.node.level === 1 ? 16 : 0 })
                .priorityGesture(TapGesture().onAction((): void => { this.openChapter(section) }), GestureMask.IgnoreInternal)
                .accessibilityDescription(`${section.node.level} 级章节，点击定位正文`)
            }
          }
        }, (section: ProjectReadingSection) => section.key)
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%').padding(24)
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        if (this.headerEntries.length > 0 || this.tagOptions.length > 0 || this.category) {
          ProjectFileHeader({ headerEntries: this.headerEntries, fileVersion: this.headerVersion, categoryOptions: this.categoryOptions,
            beforeEdit: this.beforeHeaderEdit, save: this.saveHeader, navigation: this.headerNavigation,
            tags: this.tagOptions, selectedTags: this.selectedTags,
            category: this.category, selectedCategory: this.selectedCategory,
            toggle: this.toggleTag, toggleCategory: this.toggleCategory }).width('100%')
            .onAreaChange((_old: Area, area: Area): void => {
              this.headerHeight = Number(area.height)
              this.scheduleInitialOffset()
            })
        }
        ForEach(this.sections, (section: ProjectReadingSection) => {
          Column({ space: section.node ? 0 : 12 }) {
            if (!section.node && section.blocks.length > 0) {
              Text('导言').fontSize(12).fontColor(UiColor.projectLabel).width('100%')
            }
            if (section.node) {
              ProjectTaskSection({ dataSet: this.taskDataSet(), taskId: section.key, hasChildren: this.parentKeys.includes(section.key), contextOnly: this.contextKeys.includes(section.key),
                internalLinkProcessor: this.internalLinkProcessor, specialTags: this.specialTags, scrollHost: this.scroller }).width('100%')
            } else if (section.blocks.length > 0) {
              ProjectSectionBody({ internalLinkProcessor: this.internalLinkProcessor, task: null, blocks: section.blocks,
                contentBackground: UiColor.projectBlock }).width('100%')
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
            .padding({ left: section.node ? 0 : (section.blocks.length > 0 ? 16 : 0),
              right: !section.node && section.blocks.length > 0 ? 16 : 0,
              top: !section.node && section.blocks.length > 0 ? 16 : 0, bottom: !section.node && section.blocks.length > 0 ? 16 : 0 })
            .backgroundColor(section.node ? Color.Transparent : UiColor.projectBlock).borderRadius(section.node ? 0 : 12)
            .visibility(this.visibleKeys.includes(section.key) ? Visibility.Visible : Visibility.None)
            .onAreaChange((_old: Area, area: Area): void => { this.offsets.set(section.key, Number(area.position.y)) })
        }, (section: ProjectReadingSection) => `${this.revision}:${section.key}`)
        if (this.tagFiltered && !this.readingItems.some(item => item.visible && item.section.node?.state && !item.contextOnly)) {
          Text('没有匹配标签的任务').fontSize(14).fontColor(UiColor.secondary).padding({ top: 48, bottom: 48 })
        }
        if (this.sections.every((section: ProjectReadingSection) => section.node === null && section.blocks.length === 0)) {
          Text('项目还没有内容').fontSize(14).fontColor(UiColor.secondary).padding({ top: 64, bottom: 64 })
        }
      }.width('100%').padding({ left: 12, right: 12, top: 4, bottom: 48 })
        .onAreaChange((_old: Area, area: Area): void => {
          this.contentHeight = Number(area.height)
          this.scheduleInitialOffset()
        })
    }.id('project_document_scroll').width('100%').height('100%').align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .onAppear((): void => { this.ready() })
      .onDidScroll((): void => { if (this.showing) this.scrolled(this.scroller.currentOffset().yOffset) })
      .onAreaChange((_old: Area, area: Area): void => {
        this.viewportHeight = Number(area.height)
        this.scheduleInitialOffset()
        if (this.showing && Number(area.height) > 0 && this.pendingOffset !== undefined &&
          (this.initialOffsetApplied || this.pendingOffset !== 0)) {
          this.scroller.scrollTo({ xOffset: 0, yOffset: this.pendingOffset, animation: false })
          this.pendingOffset = undefined
          this.initialOffsetApplied = true
        }
      })
      .bindSheet($$this.outlineVisible, this.outlineSheet(), {
        height: '70%', detents: ['70%', '95%'], preferType: SheetType.BOTTOM,
        backgroundColor: UiColor.surface, showClose: true
      })
  }
}
