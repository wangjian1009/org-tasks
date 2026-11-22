import { CoreTask, CoreTaskModification, CoreContentBlock, CoreTaskChecklistItem } from '../services/NativeCoreService'
import { DataSet, TaskDataSource } from '../services/DataSet'
import { samePageValue } from '../services/PageDataEquality'
import { TaskInlineSession } from '../services/TaskInlineService'
import { InternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { TaskDateDisplay, RegionAreaPolicy } from '../ui/TaskListPresentation'
import { TaskActionItem, TaskOperation, taskPageActionPolicy, taskSelectItem } from '../ui/TaskActionPresentation'
import { UiColor } from '../ui/Theme'
import { TaskSwipeItem } from './TaskSwipeItem'
import { OrgHeadingView } from './OrgHeadingView'
import { ProjectSectionBody } from './ProjectSectionBody'
import { SwipeMenuCoordinator } from './controls/RightSwipe'
import { PopupMenuItem } from './controls/PopupMenu'
import { PopupMenuButton } from './controls/PopupMenuButton'
import { TaskSelectionRow } from './TaskSelectionRow'
import { ProjectEditPhase, ProjectEditRow } from '../ui/ProjectStructurePresentation'

interface ProjectBlockItemValue { text: string; checked: boolean; partial: boolean; depth: number }
interface ProjectBlockValue { kind: string; source: string; html: string; paragraph: boolean; blankLinesBefore: number; items: ProjectBlockItemValue[] }

// 章节按稳定行身份订阅 Task，属性变化不重建文档容器或其他章节。
@Component
export struct ProjectTaskSection {
  dataSet: DataSet | undefined = undefined
  taskId: string = ''
  @Prop specialTags: string[] = []
  @Prop hasChildren: boolean = false
  @Prop contextOnly: boolean = false
  @Prop interactionEnabled: boolean = true
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  scrollHost: Scroller = new Scroller()
  menuCoordinator: SwipeMenuCoordinator | undefined = undefined
  @Prop canOrderChildren: boolean = false
  structureActions: (canOrder: boolean) => PopupMenuItem[] = () => []
  @Prop editPhase: ProjectEditPhase = 'idle'
  @Prop editRow: ProjectEditRow | undefined = undefined
  @Prop editBusy: boolean = false
  @Prop refactoring: boolean = false
  @Prop targetChosen: boolean = false
  @Prop targetRow: string = ''
  selectNode: () => void = () => {}
  placeNode: () => void = () => {}
  chooseNode: () => void = () => {}
  renameNode: () => void = () => {}
  dragNode: (offsetY: number, dropped: boolean) => void = () => {}
  cancelDrag: () => void = () => {}
  private actionPolicy = taskPageActionPolicy('today')
  @State node: CoreTask | undefined = undefined
  @State bodyRevision: number = 1
  @StorageLink('taskInlineActive') @Watch('inlineChanged') inlineActive: string = ''
  private source: TaskDataSource | undefined = undefined
  private pending: boolean = false
  private stop: (() => void) | undefined = undefined

  aboutToAppear(): void {
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
    const task = this.source?.task
    if (!task) { this.node = undefined; return }
    if (!this.node || !samePageValue(this.bodyValues(this.node.editContent.blocks), this.bodyValues(task.editContent.blocks))) this.bodyRevision++
    this.node = task
  }

  async modify(changes: CoreTaskModification[], sourceVersion?: string): Promise<CoreTask> {
    const task = this.source?.task
    if (!task) throw new Error('当前章节已移除')
    const version = sourceVersion ?? task.fileVersion
    if (changes.some(change => change.field === 'CHECKLIST')) {
      return await this.dataSet!.commitTaskFields(this.taskId, changes, version)
    }
    return await this.dataSet!.updateTask(this.taskId, changes, version)
  }

  // 位置 ID 和文件版本是编辑上下文；只在可见正文改变时更新 HTML 修订号。
  bodyValues(blocks: CoreContentBlock[]): ProjectBlockValue[] {
    return blocks.map((block: CoreContentBlock): ProjectBlockValue => ({
      kind: block.kind, source: block.source, html: block.html,
      paragraph: block.paragraph, blankLinesBefore: block.blankLinesBefore,
      items: block.items.map((item: CoreTaskChecklistItem): ProjectBlockItemValue => ({ text: item.text, checked: item.checked, partial: item.partial, depth: item.depth }))
    }))
  }

  private chapterActions(close: () => void): TaskActionItem[] {
    return this.structureActions(this.canOrderChildren).filter(item => ['任务', '章节', '放置'].includes(item.title))
      .map((item): TaskActionItem => ({
        id: item.title === '任务' ? TaskOperation.Project : item.title === '章节' ? TaskOperation.Memo : TaskOperation.Place,
        title: item.title, label: item.title === '任务' ? '添加任务' : item.title === '章节' ? '添加章节' : '在项目内放置章节',
        icon: item.icon!, action: (): void => { close(); item.action() }
      })).concat(taskSelectItem((): void => { close(); this.selectNode() }))
  }

  @Builder
  editingHeading() {
    Row({ space: 8 }) {
      Image(this.node?.state ? $r('app.media.ui_task_list') : $r('app.media.ui_document_outline'))
        .width(18).height(18).accessibilityLevel('no')
      Text(this.editRow?.title ?? this.node?.heading ?? '').fontSize(this.node?.state ? 16 : 18).fontColor(UiColor.text)
        .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.editRow?.covered && this.editRow.selected < 0) { Text('随父项').fontSize(12).fontColor(UiColor.secondary) }
    }.width('100%').constraintSize({ minHeight: 44 })
  }

  @Builder
  editControls() {
    Row() {
      Column() {
        TaskSelectionRow({ selecting: true, busy: this.editBusy || this.editPhase === 'review' ||
          (this.editPhase === 'target' && !!this.editRow?.covered),
          heading: this.editRow?.title ?? this.node?.heading ?? '',
          selectedIndex: this.editPhase === 'target' ? (this.targetChosen && this.targetRow === this.taskId ? 0 : -1) :
            this.editRow?.selected ?? -1,
          toggle: this.chooseNode }) {
          this.editingHeading()
        }
      }.layoutWeight(1).constraintSize({ minWidth: 0 })
      if (this.refactoring && this.editPhase === 'select') {
        Row() {
          Image($r('app.media.ui_drag_handle')).width(22).height(22).draggable(false)
        }.width(44).height(44).justifyContent(FlexAlign.Center).enabled(!this.editBusy)
          .accessibilityText(`长按排序，${this.editRow?.title ?? ''}`)
          .gesture(GestureGroup(GestureMode.Sequence, LongPressGesture({ repeat: false, duration: 300 }),
            PanGesture({ direction: PanDirection.Vertical, distance: 4 })
              .onActionUpdate((event: GestureEvent): void => { this.dragNode(event.offsetY, false) })
              .onActionEnd((event: GestureEvent): void => { this.dragNode(event.offsetY, true) })
              .onActionCancel(this.cancelDrag)).onCancel(this.cancelDrag))
        PopupMenuButton({ icon: $r('app.media.ui_more_horizontal'), label: '节点操作', buttonWidth: 36, buttonHeight: 44,
          disabled: this.editBusy, items: [
            { title: '改名', icon: $r('app.media.ui_link_edit'), action: this.renameNode },
            { title: '放置', icon: $r('app.media.ui_place'), action: this.placeNode }
          ] })
      }
    }.width('100%')
  }

  build() {
    Column() {
      if (this.node) {
        if (this.editPhase !== 'idle') {
          this.editControls()
        } else if (this.node.state) {
          TaskSwipeItem({ listItem: false, menuCoordinator: this.menuCoordinator, interactionEnabled: this.interactionEnabled,
            singleOperations: this.actionPolicy.singleOperations, rightSwipeAction: this.actionPolicy.rightSwipeAction,
            menuIdPrefix: 'project_swipe', dataSet: this.dataSet!, taskId: this.taskId, internalLinkProcessor: this.internalLinkProcessor,
            contentHidden: this.hasChildren || this.contextOnly, hiddenTags: this.specialTags, instanceKey: `project:${this.taskId}`,
            structureActions: this.structureActions, canOrderChildren: this.canOrderChildren, projectStructure: true,
            placeNode: this.placeNode, selectNode: this.selectNode,
            dateDisplay: TaskDateDisplay.Schedule, regionAreaPolicy: RegionAreaPolicy.None,
            scrollHost: this.scrollHost, scrollHostId: 'project_document_scroll' }).width('100%')
        } else {
          OrgHeadingView({ internalLinkProcessor: this.internalLinkProcessor, node: this.node, specialTags: this.specialTags,
            structureActions: this.structureActions, canOrderChildren: this.canOrderChildren,
            menuCoordinator: this.menuCoordinator, swipeEnabled: this.interactionEnabled,
            swipeActions: (close: () => void): TaskActionItem[] => this.chapterActions(close),
            modify: async (changes: CoreTaskModification[]): Promise<void> => {
              await this.modify(changes)
            } }).width('100%')
        }
        if (!this.node.state || this.hasChildren) {
          ProjectSectionBody({ modify: async (task: CoreTask, changes: CoreTaskModification[]): Promise<CoreTask> => {
            return await this.modify(changes, task.fileVersion)
          }, readTask: (): CoreTask | undefined => this.source?.task,
            internalLinkProcessor: this.internalLinkProcessor, task: this.node, blocks: this.node.editContent.blocks,
            contentRevision: `${this.bodyRevision}`, contentBackground: UiColor.surface }).width('100%').enabled(this.editPhase === 'idle')
            .margin({ bottom: this.hasChildren && this.node.editContent.blocks.length > 0 ? 24 : 8 })
            .visibility(this.contextOnly || this.node.property('VISIBILITY') === 'folded' || this.node.editContent.ownTags.includes('ARCHIVE') ? Visibility.None : Visibility.Visible)
        }
      }
    }.width('100%').padding({ left: this.node ? Math.min((this.editRow?.level ?? this.node.fullPath.titles.length) - 1, 2) * 8 : 0 })
  }
}
