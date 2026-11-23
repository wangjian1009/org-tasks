import { DataSet } from '../services/DataSet'
import { InternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { OrgFileReadingSection, projectOutlineSections, projectReadingItems, OrgFileReadingItem } from '../ui/OrgFileReadingPresentation'
import { OrgFileSectionBody } from './OrgFileSectionBody'
import { OrgFileTaskSection } from './OrgFileTaskSection'
import { TaskInlineSession } from '../services/TaskInlineService'
import { UiColor } from '../ui/Theme'
import { TitleText } from './TitleText'
import { priorityColor, priorityBackground, priorityLabel } from '../ui/TaskPriorityPresentation'
import { OrgFileHeader, OrgFileHeaderNavigation } from './OrgFileHeader'
import { CoreFileHeaderEntry, CoreFileHeaderValueChange, CoreTaskPath } from '../services/NativeCoreService'
import { samePageValue } from '../services/PageDataEquality'
import { samePagePath } from '../services/PageDataSnapshot'
import { SwipeMenuCoordinator } from './controls/RightSwipe'
import { PopupMenuItem } from './controls/PopupMenu'
import { OrgFileEditRow, OrgFileEditView, projectEditIdle } from '../ui/OrgFileStructurePresentation'

export class OrgFileDocumentNavigation {
  captureReadingState: () => Promise<string> = async () => ''
  openOutline: () => void = () => {}
  closePanel: () => boolean = () => false
  locateSection: (path: CoreTaskPath) => Promise<boolean> = async (): Promise<boolean> => false
  locateCreated: (row: string, reveal: boolean) => Promise<boolean> = async () => false
  isValidInternalLink: (target: string) => Promise<boolean> = async (): Promise<boolean> => false
  followInternalLink: (target: string) => Promise<void> = async (): Promise<void> => { throw new Error('项目文档尚未载入') }
}

// 原生标题和任务行与安全 HTML 正文共用一个滚动容器。
@Component
export struct OrgFileDocumentView {
  @Prop readOnly: boolean = false
  @Prop fileContext: string = ''
  dataSet: DataSet | undefined = undefined
  private taskDataSet(): DataSet {
    if (!this.dataSet) throw new Error('项目文件数据集尚未载入')
    return this.dataSet
  }

  @Prop @Watch('updateDocument') sections: OrgFileReadingSection[] = []
  @Prop @Watch('updateDocument') focusTask: CoreTaskPath | undefined = undefined
  focusConsumed: () => void = () => {}
  @Prop @Watch('updateDocument') matchedIds: string[] = []
  @Prop @Watch('updateDocument') tagFiltered: boolean = false
  @State readingItems: OrgFileReadingItem[] = []
  @State displayedSections: OrgFileReadingSection[] = []
  @State visibleKeys: string[] = []
  @State contextKeys: string[] = []
  @State parentKeys: string[] = []
  @State highlightedRow: string = ''
  @State attentionRow: string = ''
  private focusRow: string = ''
  private focusScrolled: boolean = false
  @State dropRow: string = ''
  @State dropAfter: boolean = false
  private revealedParents: string[] = []
  private highlightTimer: number = -1
  @StorageLink('taskInlineActive') @Watch('inlineChanged') inlineActive: string = ''
  @Prop headerEntries: CoreFileHeaderEntry[] = []
  @Prop headerVersion: string = ''
  @Prop editHeaderOnAppear: boolean = false
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
  navigation: OrgFileDocumentNavigation = new OrgFileDocumentNavigation()
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  ready: () => void = () => {}
  @Prop structureOrderParents: string[] = []
  structureActions: (row: string, canOrder: boolean) => PopupMenuItem[] = () => []
  @Prop @Watch('editingChanged') edit: OrgFileEditView = projectEditIdle()
  @Prop editBusy: boolean = false
  selectNode: (row: string) => void = () => {}
  placeNode: (row: string) => void = () => {}
  chooseNode: (row: string) => void = () => {}
  renameNode: (row: string) => void = () => {}
  reorderNode: (row: string, sibling: string) => void = () => {}
  scrolled: (offset: number) => void = () => {}
  @State outlineVisible: boolean = false
  @State outlineItems: OrgFileReadingSection[] = []
  private headerNavigation: OrgFileHeaderNavigation = new OrgFileHeaderNavigation()
  private swipeMenus: SwipeMenuCoordinator = new SwipeMenuCoordinator()
  private stopTasks: (() => void) | undefined = undefined
  private updatePending: boolean = false

  linkSection(target: string): OrgFileReadingSection | undefined {
    let priority = Infinity
    let found: OrgFileReadingSection | undefined = undefined
    for (const section of this.sections) {
      if (!this.visibleKeys.includes(section.key)) continue
      for (const destination of section.linkTargets) {
        if (destination.target === target && destination.priority < priority) { found = section; priority = destination.priority }
      }
    }
    return found
  }

  private scroller: Scroller = new Scroller()
  private offsets: Map<string, number> = new Map()
  private active: boolean = false
  private navigationRevision: number = 0
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
    if (this.focusRow || this.initialOffsetApplied || (this.pendingOffset !== undefined && this.pendingOffset !== 0) ||
      this.headerHeight <= 0 || this.viewportHeight <= 0 || this.contentHeight <= 0) return
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
    this.initialOffsetApplied = this.editHeaderOnAppear || this.readOffset() !== undefined
    this.stopTasks = this.dataSet?.subscribeStructure((): void => { this.updateDocument() })
    this.updateDocument()
    this.navigation.locateSection = (path: CoreTaskPath): Promise<boolean> => this.locateSection(path)
    this.navigation.locateCreated = (row: string, reveal: boolean): Promise<boolean> => this.locateCreated(row, reveal)
    this.navigation.isValidInternalLink = async (target: string): Promise<boolean> =>
      this.active && this.showing && this.linkSection(target) !== undefined
    this.navigation.followInternalLink = async (target: string): Promise<void> => {
      const section = this.linkSection(target)
      if (!section || !this.active || !this.showing) throw new Error('内部链接目标不存在或项目文档已隐藏')
      const located = section.node
        ? await this.navigation.locateSection(section.node.fullPath)
        : await this.scrollToSection((): OrgFileReadingSection | undefined => {
          const current = this.linkSection(target)
          return current?.key === section.key ? current : undefined
        })
      if (!located) throw new Error('无法定位内部链接，请先完成当前编辑后重试')
    }
    this.pendingOffset = this.readOffset()
    this.navigation.captureReadingState = async (): Promise<string> => JSON.stringify({ scroll: this.scroller.currentOffset().yOffset })
    this.navigation.openOutline = (): void => { this.swipeMenus.close(); this.updateOutline(); this.outlineVisible = true }
    this.navigation.closePanel = (): boolean => {
      if (this.headerNavigation.close()) return true
      if (this.swipeMenus.close()) return true
      if (!this.outlineVisible) return false
      this.outlineVisible = false
      return true
    }
  }

  aboutToDisappear() {
    this.stopTasks?.(); this.stopTasks = undefined; this.active = false; this.outlineVisible = false
    clearTimeout(this.highlightTimer)
  }

  visibilityChanged() {
    if (!this.showing) { this.navigationRevision++; this.attentionRow = ''; this.swipeMenus.close(); return }
    this.pendingOffset = this.readOffset()
    this.initialOffsetApplied = this.pendingOffset !== undefined
    this.focusWhenLaidOut()
  }

  snapshotChanged() {
    this.navigationRevision++
    this.attentionRow = ''
    this.swipeMenus.close()
    this.offsets.clear()
    this.revealedParents = []
    if (this.focusRow) this.revealAncestors(this.focusRow)
    this.outlineVisible = false
    const offset = this.readOffset()
    this.initialOffsetApplied = offset !== undefined
    this.pendingOffset = offset ?? 0
    this.scroller.scrollTo({ xOffset: 0, yOffset: offset ?? 0, animation: false })
    if (offset === undefined) this.scheduleInitialOffset()
    this.ready()
  }

  private locateSection(path: CoreTaskPath): Promise<boolean> {
    return this.scrollToSection((): OrgFileReadingSection | undefined => this.sectionAt(path))
  }

  private sectionAt(path: CoreTaskPath): OrgFileReadingSection | undefined {
    return this.sections.find(section => {
      const node = this.dataSet?.getTask(section.key) ?? section.node
      return node !== null && samePagePath(node.fullPath, path)
    })
  }

  private focusWhenLaidOut(): void {
    if (!this.active || !this.showing || !this.focusRow || this.viewportHeight <= 0 || this.contentHeight <= 0) return
    const row = this.focusRow
    const offset = this.offsets.get(row)
    if (offset === undefined || !this.visibleKeys.includes(row)) return
    this.focusRow = ''
    this.focusScrolled = true
    this.scrollToOffset(offset)
    this.attentionRow = row
    this.focusConsumed()
  }

  private async locateCreated(row: string, reveal: boolean): Promise<boolean> {
    if (!await this.locateRow(row, reveal)) return false
    this.highlightedRow = row
    clearTimeout(this.highlightTimer)
    this.highlightTimer = setTimeout((): void => { this.highlightedRow = '' }, 2400)
    return true
  }

  private async locateRow(row: string, reveal: boolean): Promise<boolean> {
    const revision = this.navigationRevision
    if (reveal) {
      this.revealAncestors(row)
      this.updateDocument()
    }
    for (let attempt = 0; attempt < 12 && this.active && this.showing && revision === this.navigationRevision; attempt++) {
      if (await this.scrollToSection((): OrgFileReadingSection | undefined => this.sections.find(section => section.key === row))) return true
      await new Promise<void>(resolve => setTimeout(resolve, 50))
    }
    return false
  }

  private revealAncestors(row: string): void {
    const index = this.sections.findIndex(item => item.key === row)
    if (index < 0) return
    let level = (this.dataSet?.getTask(row) ?? this.sections[index].node)?.level ?? 0
    for (let prior = index - 1; prior >= 0; prior--) {
      const section = this.sections[prior]
      const node = this.dataSet?.getTask(section.key) ?? section.node
      if (node && node.level < level) {
        if (!this.revealedParents.includes(section.key)) this.revealedParents.push(section.key)
        level = node.level
      }
    }
  }

  private async scrollToSection(resolve: () => OrgFileReadingSection | undefined): Promise<boolean> {
    const revision = this.navigationRevision
    if (!this.active || !this.showing || !resolve() || !await TaskInlineSession.end(false)) return false
    if (!this.active || !this.showing || revision !== this.navigationRevision) return false
    const section = resolve()
    if (!section || !this.visibleKeys.includes(section.key)) return false
    const offset = this.offsets.get(section.key)
    if (offset === undefined) return false
    this.scrollToOffset(offset)
    return true
  }

  private scrollToOffset(offset: number): void {
    this.pendingOffset = undefined
    this.initialOffsetApplied = true
    this.swipeMenus.close()
    this.outlineVisible = false
    this.scroller.scrollTo({ xOffset: 0, yOffset: Math.max(0, offset - 12), animation: false })
  }

  updateOutline(): void {
    this.outlineItems = projectOutlineSections(this.readingItems.filter(item => item.visible).map(item => item.section).map((section: OrgFileReadingSection): OrgFileReadingSection => ({
      key: section.key, node: section.node ? this.dataSet?.getTask(section.key) ?? section.node : null,
      html: section.html, blocks: section.blocks, linkTargets: section.linkTargets
    })))
  }

  updateDocument(): void {
    if (TaskInlineSession.active()) { this.updatePending = true; return }
    this.updatePending = false
    const current = this.sections.map((section: OrgFileReadingSection): OrgFileReadingSection => ({
      key: section.key, node: section.node ? this.dataSet?.getTask(section.key) ?? section.node : null,
      html: section.html, blocks: section.blocks, linkTargets: section.linkTargets
    }))
    const editing = this.edit.phase !== 'idle'
    const focus = this.focusTask ? this.sectionAt(this.focusTask) : undefined
    if (focus?.node?.state && !editing && !this.focusScrolled && this.focusRow !== focus.key) {
      this.focusRow = focus.key
      this.revealAncestors(focus.key)
    } else if (!focus) {
      this.focusRow = ''
      this.focusScrolled = false
    }
    const levels = new Map<string, number>()
    let displayed = current
    if (editing) {
      const byRow = new Map<string, OrgFileReadingSection>()
      current.forEach(section => byRow.set(section.key, section))
      displayed = current.filter(section => section.node === null)
      for (const row of this.edit.rows) {
        const section = byRow.get(row.row)
        if (section) { displayed.push(section); levels.set(row.row, row.level) }
      }
    }
    this.displayedSections = displayed
    this.readingItems = projectReadingItems(displayed, !editing && this.tagFiltered ? this.matchedIds : null,
      editing ? this.edit.rows.map(row => row.row) : this.revealedParents, levels)
    const visible = this.readingItems.filter(item => item.visible).map(item => item.section.key)
    const contexts = this.readingItems.filter(item => item.contextOnly).map(item => item.section.key)
    const parents = this.readingItems.filter(item => item.hasChildren).map(item => item.section.key)
    if (!samePageValue(this.visibleKeys, visible)) this.visibleKeys = visible
    if (!samePageValue(this.contextKeys, contexts)) this.contextKeys = contexts
    if (!samePageValue(this.parentKeys, parents)) this.parentKeys = parents
    if (this.outlineVisible) this.updateOutline()
  }

  editingChanged(): void {
    this.swipeMenus.close()
    this.dropRow = ''
    this.updateDocument()
  }

  private draftRow(row: string): OrgFileEditRow | undefined { return this.edit.rows.find(item => item.row === row) }

  private dragRow(row: string, offset: number, dropped: boolean): void {
    if (this.editBusy || !this.edit.refactoring || this.edit.phase !== 'select') return
    const source = this.edit.rows.findIndex(item => item.row === row)
    const origin = this.offsets.get(row)
    if (source < 0 || origin === undefined) return
    const level = this.edit.rows[source].level
    // 同层节点以最近的较浅标题划定同一父节点的排序范围。
    let first = source, last = source
    while (first > 0 && this.edit.rows[first - 1].level >= level) first--
    while (last + 1 < this.edit.rows.length && this.edit.rows[last + 1].level >= level) last++
    const y = origin + offset
    let target = ''
    let distance = Math.abs(offset)
    for (let index = first; index <= last; index++) {
      const candidate = this.edit.rows[index]
      if (candidate.level !== level || index === source) continue
      const position = this.offsets.get(candidate.row)
      if (position === undefined) continue
      if (Math.abs(y - position) < distance) {
        distance = Math.abs(y - position)
        target = candidate.row
      }
    }
    this.dropAfter = offset > 0
    this.dropRow = dropped ? '' : target
    if (dropped && target && Math.abs(offset) >= 18) this.reorderNode(row, target)
  }

  inlineChanged(): void { if (!this.inlineActive && this.updatePending) this.updateDocument() }

  @Builder
  outlineSheet() {
    Column({ space: 12 }) {
      Text('文档目录').fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text).width('100%')
      if (this.outlineItems.length === 0) {
        Text('本文没有章节标题').fontSize(14).fontColor(UiColor.secondary).padding(24)
      }
      List() {
        ForEach(this.outlineItems, (section: OrgFileReadingSection) => {
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
                .priorityGesture(TapGesture().onAction((): void => {
                  if (section.node) this.navigation.locateSection(section.node.fullPath)
                }), GestureMask.IgnoreInternal)
                .accessibilityDescription(`${section.node.level} 级章节，点击定位正文`)
            }
          }
        }, (section: OrgFileReadingSection) => section.key)
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
    }.width('100%').height('100%').padding(24)
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        if (this.fileContext) {
          Text(this.fileContext).fontSize(12).fontColor(UiColor.secondary).width('100%').padding(8)
        }
        if (!this.readOnly && (this.headerEntries.length > 0 || this.tagOptions.length > 0 || this.category)) {
          OrgFileHeader({ headerEntries: this.headerEntries, fileVersion: this.headerVersion, categoryOptions: this.categoryOptions,
            editOnAppear: this.editHeaderOnAppear,
            beforeEdit: this.beforeHeaderEdit, save: this.saveHeader, navigation: this.headerNavigation,
            tags: this.tagOptions, selectedTags: this.selectedTags,
            category: this.category, selectedCategory: this.selectedCategory,
            toggle: this.toggleTag, toggleCategory: this.toggleCategory }).width('100%').enabled(this.edit.phase === 'idle')
            .onAreaChange((_old: Area, area: Area): void => {
              this.headerHeight = Number(area.height)
              this.scheduleInitialOffset()
            })
        }
        ForEach(this.displayedSections, (section: OrgFileReadingSection) => {
          Column({ space: section.node ? 0 : 12 }) {
            if (this.dropRow === section.key && !this.dropAfter) { Divider().color(UiColor.primary).strokeWidth(2) }
            if (!section.node && section.blocks.length > 0) {
              Text('导言').fontSize(12).fontColor(UiColor.projectLabel).width('100%')
            }
            if (section.node && this.readOnly) {
              TitleText({ text: section.node.heading, parts: section.node.headingParts, textSize: 17, weight: FontWeight.Medium })
                .width('100%').padding({ left: Math.min(section.node.level - 1, 4) * 12, top: 8 })
              if (section.blocks.length > 0) {
                OrgFileSectionBody({ task: null, blocks: section.blocks, internalLinkProcessor: this.internalLinkProcessor })
                  .width('100%')
              }
            } else if (section.node) {
              OrgFileTaskSection({ dataSet: this.taskDataSet(), taskId: section.key, hasChildren: this.parentKeys.includes(section.key), contextOnly: this.contextKeys.includes(section.key),
                attentionRequested: this.showing && this.attentionRow === section.key,
                attentionStarted: (): void => { if (this.attentionRow === section.key) this.attentionRow = '' },
                menuCoordinator: this.swipeMenus, interactionEnabled: this.showing && this.visibleKeys.includes(section.key),
                canOrderChildren: this.structureOrderParents.includes(section.key),
                structureActions: (canOrder: boolean): PopupMenuItem[] => this.structureActions(section.key, canOrder),
                editPhase: this.edit.phase, editRow: this.draftRow(section.key), editBusy: this.editBusy,
                refactoring: this.edit.refactoring, targetChosen: this.edit.targetChosen, targetRow: this.edit.target,
                placeNode: (): void => { this.placeNode(section.key) }, selectNode: (): void => { this.selectNode(section.key) },
                chooseNode: (): void => { this.chooseNode(section.key) }, renameNode: (): void => { this.renameNode(section.key) },
                dragNode: (offset: number, dropped: boolean): void => { this.dragRow(section.key, offset, dropped) },
                cancelDrag: (): void => { this.dropRow = '' },
                internalLinkProcessor: this.internalLinkProcessor, specialTags: this.specialTags, scrollHost: this.scroller }).width('100%')
            } else if (section.blocks.length > 0) {
              OrgFileSectionBody({ internalLinkProcessor: this.internalLinkProcessor, task: null, blocks: section.blocks,
                contentBackground: UiColor.projectBlock }).width('100%')
            }
            if (this.dropRow === section.key && this.dropAfter) { Divider().color(UiColor.primary).strokeWidth(2) }
          }.width('100%').alignItems(HorizontalAlign.Start)
            .padding({ left: section.node ? 0 : (section.blocks.length > 0 ? 16 : 0),
              right: !section.node && section.blocks.length > 0 ? 16 : 0,
              top: !section.node && section.blocks.length > 0 ? 16 : 0, bottom: !section.node && section.blocks.length > 0 ? 16 : 0 })
            .backgroundColor(this.highlightedRow === section.key ? UiColor.field : section.node ? Color.Transparent : UiColor.projectBlock)
            .borderRadius(section.node ? 0 : 12)
            .visibility(this.visibleKeys.includes(section.key) ? Visibility.Visible : Visibility.None)
            .onAreaChange((_old: Area, area: Area): void => {
              if (Number(area.height) <= 0) { this.offsets.delete(section.key); return }
              this.offsets.set(section.key, Number(area.position.y))
              if (section.key === this.focusRow) this.focusWhenLaidOut()
            })
        }, (section: OrgFileReadingSection) => `${this.revision}:${section.key}`)
        if (this.edit.phase === 'idle' && this.tagFiltered && !this.readingItems.some(item => item.visible && item.section.node?.state && !item.contextOnly)) {
          Text('没有匹配标签的任务').fontSize(14).fontColor(UiColor.secondary).padding({ top: 48, bottom: 48 })
        }
        if (this.sections.every((section: OrgFileReadingSection) => section.node === null && section.blocks.length === 0)) {
          Text('文件还没有内容').fontSize(14).fontColor(UiColor.secondary).padding({ top: 64, bottom: 64 })
        }
      }.width('100%').padding({ left: 12, right: 12, top: 4, bottom: 48 })
        .onAreaChange((_old: Area, area: Area): void => {
          this.contentHeight = Number(area.height)
          this.scheduleInitialOffset()
          this.focusWhenLaidOut()
        })
    }.id('project_document_scroll').width('100%').height('100%').align(Alignment.Top)
      .scrollBar(BarState.Off)
      .onAppear((): void => { this.ready() })
      .onScrollStart((): void => { this.swipeMenus.close() })
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
        this.focusWhenLaidOut()
      })
      .bindSheet($$this.outlineVisible, this.outlineSheet(), {
        height: '70%', detents: ['70%', '95%'], preferType: SheetType.BOTTOM,
        backgroundColor: UiColor.surface, showClose: true
      })
  }
}
