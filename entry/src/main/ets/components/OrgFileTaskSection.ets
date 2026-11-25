import { localizedText } from '../ui/LocalizedText'
import { CoreTask, CoreTaskModification } from '../services/NativeCoreService'
import { DataSet, TaskDataSource } from '../services/DataSet'
import { TaskInlineSession } from '../services/TaskInlineService'
import { InternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { TaskDateDisplay, RegionAreaPolicy } from '../ui/TaskListPresentation'
import { TaskActionItem, TaskOperation, taskPageActionPolicy } from '../ui/TaskActionPresentation'
import { UiColor } from '../ui/Theme'
import { TaskSwipeItem } from './TaskSwipeItem'
import { OrgHeadingView } from './OrgHeadingView'
import { OrgFileSectionBody } from './OrgFileSectionBody'
import { TitleText } from './TitleText'
import { TaskEditor } from './editors/TaskEditor'
import { SwipeMenuCoordinator } from './controls/RightSwipe'
import { PopupMenuItem } from './controls/PopupMenu'
import { OrgFileEditRow } from '../ui/OrgFileStructurePresentation'

// 章节按稳定行身份订阅 Task，属性变化不重建文档容器或其他章节。
@Component
export struct OrgFileTaskSection {
  dataSet: DataSet | undefined = undefined
  taskId: string = ''
  @Prop specialTags: string[] = []
  @Prop hasChildren: boolean = false
  @Prop contextOnly: boolean = false
  @Prop attentionRequested: boolean = false
  attentionStarted: () => void = () => {}
  @Prop interactionEnabled: boolean = true
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  scrollHost: Scroller = new Scroller()
  menuCoordinator: SwipeMenuCoordinator | undefined = undefined
  @Prop canOrderChildren: boolean = false
  structureActions: (canOrder: boolean) => PopupMenuItem[] = () => []
  @Prop editRow: OrgFileEditRow | undefined = undefined
  @Prop editBusy: boolean = false
  @Prop orderFolded: boolean = false
  @Prop orderDragActive: boolean = false
  toggleOrderFold: () => void = () => {}
  @Prop dragging: boolean = false
  @Prop dragOffset: number = 0
  @Prop @Watch('highlightChanged') highlighted: boolean = false
  @State highlightColor: string = '#00000000'
  beginDrag: (event: GestureEvent) => void = () => {}
  dragNode: (event: GestureEvent, dropped: boolean) => void = () => {}
  cancelDrag: () => void = () => {}
  private actionPolicy = taskPageActionPolicy('today')
  @State node: CoreTask | undefined = undefined
  @State addContentRequest: number = 0
  @StorageLink('taskInlineActive') @Watch('inlineChanged') inlineActive: string = ''
  private source: TaskDataSource | undefined = undefined
  private pending: boolean = false
  private stop: (() => void) | undefined = undefined

  aboutToAppear(): void {
    this.highlightChanged()
    this.source = this.dataSet!.taskSource(this.taskId)
    this.stop = this.source.monitor((): void => {
      this.pending = true
      if (!TaskInlineSession.active()) this.applyTask()
    })
  }

  aboutToDisappear(): void { this.stop?.(); this.stop = undefined; this.source = undefined }
  inlineChanged(): void { if (!this.inlineActive && this.pending) this.applyTask() }

  applyTask(): void {
    this.pending = false
    this.node = this.source?.task
  }

  async modify(changes: CoreTaskModification[]): Promise<void> {
    const task = this.source?.task
    if (!task) throw new Error(localizedText($r('app.string.text_current_chapter_removed')))
    await this.dataSet!.updateTask(this.taskId, changes, task.fileVersion)
  }

  private highlightChanged(): void {
    if (!this.highlighted) {
      this.highlightColor = '#00000000'
      return
    }
    this.getUIContext().keyframeAnimateTo({ iterations: 1 }, [
      { duration: 120, curve: Curve.EaseOut, event: (): void => { this.highlightColor = '#737CC9B8' } },
      { duration: 150, curve: Curve.EaseInOut, event: (): void => { this.highlightColor = '#00000000' } },
      { duration: 120, curve: Curve.EaseOut, event: (): void => { this.highlightColor = '#737CC9B8' } },
      { duration: 380, curve: Curve.EaseOut, event: (): void => { this.highlightColor = '#00000000' } }
    ])
  }

  private chapterActions(close: () => void): TaskActionItem[] {
    const items = this.structureActions(false)
      .map((item): TaskActionItem => ({
        id: item.title === localizedText($r('app.string.text_tasks_2')) ? TaskOperation.Project : item.title === localizedText($r('app.string.text_section')) ? TaskOperation.Memo : TaskOperation.Refactor,
        title: item.title, label: item.title === localizedText($r('app.string.text_tasks_2')) ? localizedText($r('app.string.text_add_task')) : item.title === localizedText($r('app.string.text_section')) ? localizedText($r('app.string.text_add_chapter')) : localizedText($r('app.string.text_reconstruct_chapter')),
        icon: item.icon!, action: (): void => { close(); item.action() }
      }))
    if (this.canAddContent()) {
      items.unshift({ id: 'addContent', title: localizedText($r('app.string.text_add')), label: localizedText($r('app.string.text_add_chapter_2')), icon: $r('app.media.ui_add'),
        action: (): void => { close(); this.addContent() } })
    }
    return items
  }

  private canAddContent(): boolean {
    return !!this.node && this.interactionEnabled && !this.contextOnly &&
      this.node.property('VISIBILITY') !== 'folded' && !this.node.editContent.ownTags.includes('ARCHIVE')
  }

  private addContent(): void {
    if (this.canAddContent()) this.addContentRequest++
  }

  @Builder
  orderHeading() {
    Row({ space: 8 }) {
      if (this.hasChildren) {
        Button({ type: ButtonType.Normal }) {
          Image(this.orderFolded ? $r('app.media.ui_next') : $r('app.media.ui_down'))
            .width(14).height(14).fillColor(UiColor.secondary).accessibilityLevel('no')
        }.id(`project_order_fold:${this.taskId}`).width(28).height(44).padding(0)
          .backgroundColor(Color.Transparent).enabled(!this.orderDragActive)
          .accessibilityText(`${this.orderFolded ? localizedText($r('app.string.text_expand_subpoints')) : localizedText($r('app.string.text_collapse_subnodes'))}，${this.node?.heading ?? ''}`)
          .onClick(this.toggleOrderFold)
      } else {
        Blank().width(28)
      }
      if (this.node?.state) {
        TaskEditor({ previewTask: this.node, readOnly: true, titleOnly: true }).layoutWeight(1)
      } else {
        Image($r('app.media.ui_document_outline')).width(18).height(18).accessibilityLevel('no')
        TitleText({ text: this.node?.heading ?? '', parts: this.node?.headingParts ?? [],
          textSize: 18, lineLimit: 2, openLinks: false }).layoutWeight(1)
      }
      if (this.editRow?.canReorder) {
        Row() {
          Image($r('app.media.ui_drag_handle')).width(22).height(22).draggable(false)
        }.id(`project_order_drag:${this.taskId}`).width(44).height(44).justifyContent(FlexAlign.Center).enabled(!this.editBusy)
          .accessibilityText(localizedText($r('app.string.text_long_press_drag'), String(this.node?.heading ?? '')))
          .gesture(GestureGroup(GestureMode.Sequence, LongPressGesture({ repeat: false, duration: 300 }),
            PanGesture({ direction: PanDirection.Vertical, distance: 4 })
              .onActionStart(this.beginDrag)
              .onActionUpdate((event: GestureEvent): void => { this.dragNode(event, false) })
              .onActionEnd((event: GestureEvent): void => { this.dragNode(event, true) })
              .onActionCancel(this.cancelDrag)).onCancel(this.cancelDrag))
      } else { Blank().width(44) }
    }.id(`project_order_heading:${this.taskId}`).width('100%').constraintSize({ minHeight: 44 })
      .backgroundColor(this.dragging ? UiColor.container : this.highlightColor).borderRadius(8)
      .shadow(this.dragging ? { radius: 8, color: '#52000000', offsetY: 4 } : { radius: 0 })
      .translate({ y: this.dragOffset })
  }

  build() {
    Column() {
      if (this.node) {
        if (this.editRow) {
          this.orderHeading()
        } else if (this.node.state) {
          TaskSwipeItem({ listItem: false, menuCoordinator: this.menuCoordinator, interactionEnabled: this.interactionEnabled,
            attentionRequested: this.attentionRequested, attentionStarted: this.attentionStarted,
            singleOperations: this.actionPolicy.singleOperations, rightSwipeAction: this.actionPolicy.rightSwipeAction,
            menuIdPrefix: 'project_swipe', dataSet: this.dataSet!, taskId: this.taskId, internalLinkProcessor: this.internalLinkProcessor,
            contentHidden: this.hasChildren || this.contextOnly, hiddenTags: this.specialTags, instanceKey: `project:${this.taskId}`,
            canAddContent: this.canAddContent(), addContent: (): void => { this.addContent() },
            addContentRequest: !this.hasChildren ? this.addContentRequest : 0,
            structureActions: this.structureActions, canOrderChildren: this.canOrderChildren,
            includeStructureActions: true, shortActionLabels: true,
            dateDisplay: TaskDateDisplay.Schedule, regionAreaPolicy: RegionAreaPolicy.None,
            scrollHost: this.scrollHost, scrollHostId: 'project_document_scroll' }).width('100%')
        } else {
          OrgHeadingView({ internalLinkProcessor: this.internalLinkProcessor, node: this.node, specialTags: this.specialTags,
            menuCoordinator: this.menuCoordinator, swipeEnabled: this.interactionEnabled,
            swipeActions: (close: () => void): TaskActionItem[] => this.chapterActions(close),
            modify: async (changes: CoreTaskModification[]): Promise<void> => {
              await this.modify(changes)
            } }).width('100%')
        }
        if (!this.editRow && (!this.node.state || this.hasChildren)) {
          OrgFileSectionBody({ dataSet: this.dataSet, taskId: this.taskId,
            documentContent: true, addContentRequest: this.addContentRequest,
            scrollHost: this.scrollHost, scrollHostId: 'project_document_scroll',
            internalLinkProcessor: this.internalLinkProcessor, task: this.node }).width('100%')
            .margin({ bottom: this.hasChildren && this.node.editContent.blocks.length > 0 ? 24 : 8 })
            .visibility(this.contextOnly || this.node.property('VISIBILITY') === 'folded' || this.node.editContent.ownTags.includes('ARCHIVE') ? Visibility.None : Visibility.Visible)
        }
      }
    }.width('100%').padding({ left: this.node ? Math.min((this.editRow?.level ?? this.node.fullPath.titles.length) - 1, 2) * 8 : 0 })
  }
}
