import { util } from '@kit.ArkTS'
import { CoreBridgeError, CoreTaskStructureEdit, coreErrorMessage } from '../../services/NativeCoreService'
import { ProjectStructureDraft, ProjectStructureNode, ProjectStructureSnapshot, projectOrderMove, projectSiblings } from '../../ui/ProjectStructurePresentation'
import { UiColor } from '../../ui/Theme'
import { PopupMenu, PopupMenuItem } from '../controls/PopupMenu'

export class ProjectStructureSheetController {
  back: () => void = () => {}
}

export type ProjectStructureMode = 'add' | 'order'
export type ProjectStructureNodeKind = 'task' | 'section'

@Component
export struct ProjectStructureSheet {
  @Prop mode: ProjectStructureMode = 'add'
  @Prop snapshot: ProjectStructureSnapshot
  @Prop initialParent: string | null = null
  @Prop initialKind: ProjectStructureNodeKind = 'task'
  @Prop liveVersion: string = ''
  controller: ProjectStructureSheetController = new ProjectStructureSheetController()
  close: () => void = () => {}
  save: (snapshot: ProjectStructureSnapshot, edits: CoreTaskStructureEdit[]) => Promise<string[]> = async () => []
  reload: (force: boolean) => Promise<ProjectStructureSnapshot> = async (_force: boolean) => { throw new Error('项目文件尚未载入') }
  created: (row: string) => void = () => {}

  @State parent: string | null = null
  @State titleInput: string = ''
  @State source: ProjectStructureSnapshot = { file: { repoId: '', file: null, titles: [] },
    version: '', title: '', nodes: [], hasConflict: false }
  @State ordered: ProjectStructureNode[] = []
  @State busy: boolean = false
  @State message: string = ''
  @State conflict: boolean = false
  @State dropBefore: string = ''
  @State dropAfter: string = ''
  @State gripMenu: string = ''
  private draft: ProjectStructureDraft | undefined = undefined
  aboutToAppear(): void {
    this.source = this.snapshot
    this.parent = this.initialParent
    this.resetDraft()
    this.controller.back = (): void => { this.back() }
  }

  aboutToDisappear(): void {
    this.controller.back = (): void => {}
  }

  private resetDraft(): void {
    this.draft = new ProjectStructureDraft(this.source)
    this.refresh()
  }

  private refresh(): void {
    if (!this.draft) return
    this.ordered = projectSiblings(this.draft.nodes, this.parent)
  }

  private stale(): boolean {
    return this.conflict || (!!this.liveVersion && this.liveVersion !== this.source.version)
  }

  private back(): void {
    if (!this.busy) this.close()
  }

  private async loadCurrent(): Promise<void> {
    this.busy = true
    this.message = ''
    try {
      const oldParent = this.source.nodes.find(node => node.id === this.parent)
      const latest = await this.reload(true)
      if (oldParent) {
        const current = latest.nodes.find(node => node.row === oldParent.row)
        if (!current) throw new Error('父节点已移除，请关闭面板后重新选择')
        this.parent = current.id
      }
      this.source = latest
      this.conflict = false
      this.resetDraft()
    } catch (error) { this.message = coreErrorMessage(error as CoreBridgeError) }
    finally { this.busy = false }
  }

  private async commit(edits: CoreTaskStructureEdit[], finish: boolean): Promise<void> {
    if (this.busy || this.stale()) return
    this.busy = true
    this.message = ''
    try {
      const rows = await this.save(this.source, edits)
      if (finish) {
        this.close()
        if (this.mode === 'add' && rows.length === 1) this.created(rows[0])
      } else await this.updateOrderAfterCommit()
    } catch (error) {
      this.message = coreErrorMessage(error as CoreBridgeError)
      this.conflict = this.stale() || this.message.includes('版本')
      if (!finish && this.conflict) await this.updateOrderAfterCommit()
    } finally { this.busy = false }
  }

  private async updateOrderAfterCommit(): Promise<void> {
    const oldParent = this.source.nodes.find(node => node.id === this.parent)
    try {
      const latest = await this.reload(this.conflict)
      if (oldParent) {
        const current = latest.nodes.find(node => node.row === oldParent.row)
        if (!current) throw new Error('父节点已移除，请重新选择')
        this.parent = current.id
      }
      this.source = latest
      this.resetDraft()
      this.conflict = false
    } catch (error) {
      this.conflict = true
      this.message = coreErrorMessage(error as CoreBridgeError)
    }
  }

  private applyForm(): void {
    const title = this.titleInput.trim()
    if (!title || this.busy || this.stale()) return
    this.commit([{ type: 'add', id: util.generateRandomUUID(), title, parent: this.parent, task: this.initialKind === 'task' }], true)
  }

  private sort(id: string, to: number): void {
    if (this.busy || this.stale()) return
    const position = projectOrderMove(this.draft!.nodes, id, to)
    if (!position) return
    this.commit([{ type: 'move', ids: [id], parent: position.parent, after: position.after }], false)
  }

  private sortItems(node: ProjectStructureNode): PopupMenuItem[] {
    const siblings = projectSiblings(this.draft?.nodes ?? [], node.parent)
    const index = siblings.findIndex(item => item.id === node.id)
    const actions: PopupMenuItem[] = []
    if (index > 0) actions.push({ title: '上移', icon: $r('app.media.ui_up'), action: (): void => { this.sort(node.id, index - 1) } })
    if (index + 1 < siblings.length) {
      actions.push({ title: '下移', icon: $r('app.media.ui_down'), action: (): void => { this.sort(node.id, index + 1) } })
    }
    if (index > 1) actions.push({ title: '置顶', icon: $r('app.media.ui_up'), action: (): void => { this.sort(node.id, 0) } })
    if (index + 2 < siblings.length) {
      actions.push({ title: '置底', icon: $r('app.media.ui_down'), action: (): void => { this.sort(node.id, siblings.length - 1) } })
    }
    return actions
  }

  private sortFromDrag(from: number, to: number): void {
    this.clearDrop()
    const node = this.ordered[from]
    if (node) this.sort(node.id, to)
  }

  private clearDrop(): void {
    this.dropBefore = ''
    this.dropAfter = ''
  }

  private showDrop(from: number, to: number): void {
    const nodes = this.ordered
    const target = nodes[to]
    if (from === to || !target || nodes[from]?.parent !== target.parent) {
      this.clearDrop()
      return
    }
    this.dropBefore = from > to ? target.id : ''
    this.dropAfter = from < to ? target.id : ''
  }

  @Builder
  status() {
    if (this.message) {
      Text(this.message).fontSize(13).fontColor(UiColor.error).width('100%').padding({ bottom: 8 })
    }
    if (this.stale()) {
      Text('文件已更新，请重新载入结构').fontSize(13).fontColor(UiColor.error).width('100%')
      ProjectStructureAction({ title: '重新载入结构', available: !this.busy, action: (): void => { this.loadCurrent() } })
    }
  }

  @Builder
  nodeIcon(task: boolean) {
    if (task) {
      Rect().width(16).height(16).radius(3).fill(Color.Transparent).stroke(UiColor.secondary).strokeWidth(1.5)
        .accessibilityLevel('no')
    } else {
      Image($r('app.media.ui_document_outline')).width(18).height(18).fillColor(UiColor.secondary).accessibilityLevel('no')
    }
  }

  @Builder
  grip(node: ProjectStructureNode) {
    if (this.sortItems(node).length) {
      Row() {
        Image($r('app.media.ui_drag_handle')).width(24).height(24).draggable(false).accessibilityLevel('no')
      }.width(44).height(44).justifyContent(FlexAlign.Center).focusable(true)
        .accessibilityText(`调整顺序，${node.title}`).enabled(!this.busy && !this.stale())
        .onClick((): void => { this.gripMenu = this.gripMenu === node.id ? '' : node.id })
        .bindPopup(this.gripMenu === node.id, { builder: (): void => this.gripActions(node), placement: Placement.BottomRight,
          popupColor: UiColor.menu, enableArrow: false, targetSpace: 6,
          onStateChange: (event): void => { if (!event.isVisible && this.gripMenu === node.id) this.gripMenu = '' } })
    } else {
      Blank().width(44)
    }
  }

  @Builder
  gripActions(node: ProjectStructureNode) {
    PopupMenu({ items: this.sortItems(node), maximumWidth: 180, disabled: this.busy || this.stale(),
      activate: (item: PopupMenuItem): void => { this.gripMenu = ''; item.action() } })
  }

  @Builder
  dropLine(id: string) {
    if (this.dropBefore === id || this.dropAfter === id) {
      Divider().strokeWidth(2).color(UiColor.primary)
        .align(this.dropBefore === id ? Alignment.Top : Alignment.Bottom)
    }
  }

  @Builder
  inputPanel() {
    Column({ space: 12 }) {
      TextInput({ text: this.titleInput, placeholder: this.initialKind === 'task' ? '任务标题' : '章节标题' })
        .id('project_structure_title').height(46)
        .backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary)
        .enterKeyType(EnterKeyType.Done).enabled(!this.busy)
        .onChange((value: string): void => { this.titleInput = value }).onSubmit((): void => { this.applyForm() })
      Text(this.formLocation()).fontSize(13).fontColor(UiColor.secondary).width('100%')
      this.status()
    }.width('100%').padding({top: 8, bottom: 12})
  }

  @Builder
  inputActions() {
    Row() {
      Text(this.initialKind === 'task' ? '添加任务' : '添加章节')
        .fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text).layoutWeight(1)
      ProjectStructureAction({ title: '取消', available: !this.busy, action: (): void => { this.back() } })
      Button(this.busy ? '正在保存' : '保存')
        .id('project_structure_save').height(44).fontColor(UiColor.surface).backgroundColor(UiColor.primary)
        .enabled(!this.busy && !this.stale() && !!this.titleInput.trim()).onClick((): void => { this.applyForm() })
    }.width('100%')
  }

  private formLocation(): string {
    const location = this.draft?.path(this.parent) ?? this.source.title
    return `${location} › ${this.parent === null ? '顶层首位' : '子节点首位'}`
  }

  @Builder
  orderPanel() {
    Row() {
      Text('调整子节点顺序')
        .fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text).layoutWeight(1)
      ProjectStructureAction({ title: this.busy ? '正在保存' : '完成', available: !this.busy, action: this.close })
    }.width('100%')
    Text(this.draft?.path(this.parent) ?? this.source.title).fontSize(14).fontColor(UiColor.secondary).width('100%')
    this.status()
    if (this.source.hasConflict) {
      Text('文件包含受保护的同步冲突').fontSize(13).fontColor(UiColor.secondary).width('100%').padding({top: 6, bottom: 6})
    }
    List() {
      ForEach(this.ordered, (node: ProjectStructureNode) => {
        ListItem() {
          Stack({ alignContent: Alignment.Center }) {
            Row({ space: 10 }) {
              this.nodeIcon(node.task)
              Text(node.title).layoutWeight(1).fontSize(16).fontColor(UiColor.text).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (node.hidden) { Text('筛选隐藏').fontSize(12).fontColor(UiColor.secondary) }
              this.grip(node)
            }.width('100%').constraintSize({ minHeight: 48 })
            this.dropLine(node.id)
          }.width('100%').alignContent(this.dropBefore === node.id ? Alignment.Top : Alignment.Bottom)
        }
      }, (node: ProjectStructureNode) => node.id)
        .onMove((from: number, to: number): void => { this.sortFromDrag(from, to) }, {
          onMoveThrough: (from: number, to: number): void => { this.showDrop(from, to) },
          onDrop: (): void => { this.clearDrop() }
        })
    }.layoutWeight(1).width('100%').divider({ strokeWidth: 0.5, color: UiColor.outline })
      .enabled(!this.busy && !this.stale())
  }

  build() {
    Column({ space: 6 }) {
      if (this.source) {
        if (this.mode === 'add') {
          this.inputActions()
          Scroll() { this.inputPanel() }.width('100%').layoutWeight(1).scrollBar(BarState.Auto).align(Alignment.Top)
        } else {
          this.orderPanel()
        }
      }
    }.width('100%').height('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 12 }).backgroundColor(UiColor.container)
  }
}


@Component
struct ProjectStructureAction {
  @Prop title: string = ''
  @Prop available: boolean = true
  action: () => void = () => {}

  build() {
    Button(this.title).fontSize(15).fontColor(UiColor.primary).backgroundColor(Color.Transparent)
      .constraintSize({ minHeight: 44 }).enabled(this.available).onClick(this.action)
  }
}
