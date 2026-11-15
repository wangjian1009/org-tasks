import { CoreTask, CoreTaskModification } from '../services/NativeCoreService'
import { TaskEditorDataManager } from '../services/TaskEditorDataManager'
import { InternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { ProjectReadingSection, visibleProjectTags, projectOutlineSections } from '../ui/ProjectReadingPresentation'
import { OrgFilePreviewNavigation } from './OrgFilePreviewView'
import { ProjectSectionBody } from './ProjectSectionBody'
import { OrgHeadingView } from './OrgHeadingView'
import { TaskEditor } from './editors/TaskEditor'
import { TaskInlineSession } from '../services/TaskInlineService'
import { TaskDateDisplay, RegionAreaPolicy, taskTagColor } from '../ui/TaskListPresentation'
import { UiColor } from '../ui/Theme'

export class ProjectDocumentNavigation extends OrgFilePreviewNavigation {
  isValidInternalLink: (target: string) => Promise<boolean> = async (): Promise<boolean> => false
  followInternalLink: (target: string) => Promise<void> = async (): Promise<void> => { throw new Error('项目文档尚未载入') }
}

// 原生标题和任务行与安全 HTML 正文共用一个滚动容器。
@Component
export struct ProjectDocumentView {
  dataManager: TaskEditorDataManager | undefined = undefined
  private editorDataManager(): TaskEditorDataManager {
    if (!this.dataManager) throw new Error('项目文件数据集尚未载入')
    return this.dataManager
  }

  @Prop sections: ProjectReadingSection[] = []
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
    this.navigation.isValidInternalLink = async (target: string): Promise<boolean> =>
      this.active && this.showing && this.linkSection(target) !== undefined
    this.navigation.followInternalLink = async (target: string): Promise<void> => {
      const section = this.linkSection(target)
      if (!section || !this.active || !this.showing) throw new Error('内部链接目标不存在或项目文档已隐藏')
      if (!await this.openChapter(section)) throw new Error('无法定位内部链接，请先完成当前编辑后重试')
    }
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
    let offset: number = 0
    try { offset = (JSON.parse(this.readingState) as Record<string, number>).scroll ?? 0 } catch (_) {}
    this.pendingOffset = offset
    this.scroller.scrollTo({ xOffset: 0, yOffset: offset, animation: false })
    this.ready()
  }

  async openChapter(section: ProjectReadingSection): Promise<boolean> {
    const revision = this.revision
    if (!await TaskInlineSession.end(false) || !this.active || !this.showing || revision !== this.revision) return false
    const offset = this.offsets.get(section.key)
    if (offset === undefined) return false
    this.outlineVisible = false
    this.scroller.scrollTo({ xOffset: 0, yOffset: Math.max(0, offset - 12), animation: false })
    return true
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
        ForEach(this.sections, (section: ProjectReadingSection) => {
          Column({ space: section.node ? 0 : 12 }) {
            if (!section.node && section.blocks.length > 0) {
              Text('导言').fontSize(12).fontColor(UiColor.projectLabel).width('100%')
            }
            if (section.node) {
              if (section.node.state) {
                TaskEditor({ dataManager: this.editorDataManager(), dataSet: this.editorDataManager().dataSetForTaskId(section.node.taskId ?? section.node.id), internalLinkProcessor: this.internalLinkProcessor, documentMode: true, contentHidden: true, hiddenTags: this.specialTags,
                  instanceKey: `project:${section.node.id}`, dateDisplay: TaskDateDisplay.Schedule,
                  regionAreaPolicy: RegionAreaPolicy.None, scrollHost: this.scroller, scrollHostId: 'project_document_scroll' })
                  .width('100%')
              } else {
                OrgHeadingView({ internalLinkProcessor: this.internalLinkProcessor, node: section.node, specialTags: this.specialTags }).width('100%')
              }
            }
            if (section.blocks.length > 0) {
              ProjectSectionBody({ modify: async (task: CoreTask, changes: CoreTaskModification[]): Promise<CoreTask> => {
                const data = this.editorDataManager().dataSetForTaskId(task.taskId ?? task.id)
                if (!data) throw new Error('项目节点已不在当前数据集中')
                return await this.editorDataManager().modifyConfirmed(data, task, changes)
              }, internalLinkProcessor: this.internalLinkProcessor, task: section.node, blocks: section.blocks,
                contentBackground: section.node ? UiColor.surface : UiColor.projectBlock }).width('100%')
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
            .padding({ left: section.node ? Math.min(section.node.fullPath.titles.length - 1, 2) * 8 : (section.blocks.length > 0 ? 16 : 0),
              right: !section.node && section.blocks.length > 0 ? 16 : 0,
              top: !section.node && section.blocks.length > 0 ? 16 : 0, bottom: !section.node && section.blocks.length > 0 ? 16 : 0 })
            .backgroundColor(section.node ? Color.Transparent : UiColor.projectBlock).borderRadius(section.node ? 0 : 12)
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
