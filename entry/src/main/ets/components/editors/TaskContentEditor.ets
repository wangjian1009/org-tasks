import { TaskContentSlot, reconcileTaskContent } from '../../ui/TaskContentPresentation'
import { InternalLinkProcessor } from '../../ui/InternalLinkProcessor'
import { CoreContentBlock, CoreTextLink, CoreLinkValue, CoreContentNode, CoreContentBlockChange, CoreTaskChecklistChange } from '../../services/NativeCoreService'
import { ChecklistFocusFrame, TaskChecklistBlock } from './TaskChecklistBlock'
import { TaskNativeContent } from './TaskNativeContent'
import { TaskBlockView } from './TaskBlockView'
import { TaskBlockController } from '../../ui/TaskBlockController'
import { LinkEditController } from '../LinkView'
import { UiColor } from '../../ui/Theme'
import { projectContentGap } from '../../ui/OrgFileReadingPresentation'

@Component
export struct TaskContentEditor {
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop @Watch('contentChanged') blocks: CoreContentBlock[] = []
  @State private slots: TaskContentSlot[] = []
  @State private movingId: string = ''
  @State private savingMove: boolean = false
  @Prop @Watch('moveContextChanged') moveVersion: string = ''
  @Prop contentTree: CoreContentNode[] | undefined = undefined
  @State private followKey: string = ''
  @State private followRequest: number = 0
  @Prop interactiveLists: boolean = false
  beginEmpty: () => Promise<boolean> = async () => false
  writeNode: (change: CoreContentBlockChange) => Promise<void> = async () => {}
  addChecklistItem: (after: string) => void = () => {}
  toggle: (change: CoreTaskChecklistChange) => void = () => {}
  @Prop @Watch('moveContextChanged') readonly: boolean = false
  @Prop projectReading: boolean = false
  @Prop checklistEditing: boolean = false
  @Prop @Watch('moveContextChanged') disabled: boolean = false
  @Prop revision: string = ''
  @Prop contentBackground: string = UiColor.taskCard
  @Prop ownerKey: string = ''
  editor: TaskBlockController = new TaskBlockController()
  linkEditor: LinkEditController = new LinkEditController()
  begin: (block: CoreContentBlock) => Promise<boolean> = async () => true
  save: (block: CoreContentBlock, source: string) => Promise<boolean> = async () => false
  moveContent: ((id: string, beforeId: string | null, version: string) => Promise<boolean>) | undefined = undefined
  changeLink: ((block: CoreContentBlock, link: CoreTextLink, value: CoreLinkValue | null) => Promise<void>) | undefined = undefined
  editingChanged: (editing: boolean) => void = () => {}
  linkEditingChanged: (editing: boolean) => void = () => {}
  @BuilderParam checklist: (index: () => number) => void = this.readChecklist

  private moveOwner: string = ''
  private selectedVersion: string = ''
  private active: boolean = false
  private emptyBlock: CoreContentBlock = { id: 'root', kind: 'text', paragraph: true, blankLinesBefore: 0, source: '', html: '', items: [] }

  aboutToAppear(): void {
    this.active = true
    this.moveOwner = `content_move_${this.getUniqueId()}`
    this.contentChanged()
  }

  aboutToDisappear(): void {
    this.active = false
    this.cancelMove()
  }

  contentChanged(): void {
    const next = reconcileTaskContent(this.slots, this.blocks)
    if (next !== this.slots) this.slots = next
    if (this.movingId && !this.savingMove && !this.blocks.some(block => block.id === this.movingId)) this.cancelMove()
  }

  moveContextChanged(): void {
    if (!this.movingId || this.savingMove) return
    if (this.selectedVersion !== this.moveVersion) {
      this.cancelMove()
      try { this.getUIContext().getPromptAction().showToast({ message: '正文已变化，请重新选择移动位置' }) }
      catch (_) { /* 宿主离开时可能没有可用窗口。 */ }
    } else if (this.readonly || this.disabled) {
      this.cancelMove()
    }
  }

  private async selectMove(block: CoreContentBlock): Promise<void> {
    const version = this.moveVersion
    if (!this.active || !version || this.readonly || this.disabled || this.movingId) return
    if (!await this.editor.begin(this.moveOwner, async (): Promise<boolean> => {
      if (this.savingMove) return false
      this.cancelMove()
      return true
    }, (): void => { this.cancelMove() })) return
    if (!this.active || version !== this.moveVersion || this.readonly || this.disabled) {
      this.cancelMove()
      return
    }
    this.selectedVersion = version
    this.movingId = block.id
  }

  private cancelMove(): void {
    this.movingId = ''
    this.selectedVersion = ''
    this.editor.release(this.moveOwner)
  }

  private async followSavedBlock(key: string, finish: () => Promise<boolean>,
    follow: (anchor: TaskContentSlot, index: number) => void): Promise<void> {
    const index = key ? this.indexFor(key) : -1
    if (key && index < 0) return
    const following = key ? this.slots[index + 1]?.key : undefined
    if (!await finish() || !this.active) return
    this.getUIContext().postFrameCallback(new ChecklistFocusFrame((): void => {
      if (!this.active || this.readonly || this.disabled) return
      const position = following ? this.indexFor(following) : this.slots.length
      const anchor = this.slots[position - 1]
      if (!anchor || (key && position <= index)) return
      follow(anchor, position - 1)
    }))
  }

  private async appendFollowingParagraph(key: string, finish: () => Promise<boolean>): Promise<void> {
    await this.followSavedBlock(key, finish, (anchor: TaskContentSlot): void => {
      this.followKey = anchor.key
      this.followRequest++
    })
  }

  private async appendFollowingChecklistItem(key: string, finish: () => Promise<boolean>): Promise<void> {
    const index = this.indexFor(key)
    await this.followSavedBlock(key, finish, (anchor: TaskContentSlot, savedIndex: number): void => {
      if (savedIndex <= index || anchor.block.kind !== 'checklist') return
      const item = anchor.block.items[0]
      if (item) this.addChecklistItem(item.id)
    })
  }

  private async saveFirstParagraph(source: string): Promise<boolean> {
    if (!source.trim()) return true
    try {
      await this.writeNode({ type: 'insertParagraph', id: 'root', source })
      return true
    } catch (_) { return false }
  }

  private validMoveGap(index: number): boolean {
    return !!this.movingId && this.blocks[index]?.id !== this.movingId && this.blocks[index - 1]?.id !== this.movingId
  }

  private async placeBlock(beforeId: string | null): Promise<void> {
    if (!this.movingId || this.savingMove || this.disabled || this.selectedVersion !== this.moveVersion || !this.moveContent) return
    this.savingMove = true
    try {
      await this.moveContent(this.movingId, beforeId, this.selectedVersion)
    } finally {
      this.savingMove = false
      this.cancelMove()
    }
  }

  @Builder
  moveGap(beforeId: string | null) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 6 }) {
        Circle({ width: 6, height: 6 }).fill(UiColor.primary)
        Divider().strokeWidth(2).color(UiColor.primary).layoutWeight(1)
      }.width('100%')
    }.width('100%').height(44).padding(0).backgroundColor(Color.Transparent)
      .enabled(!this.savingMove && !this.disabled)
      .id(beforeId === null ? 'content_move_end' : `content_move_before_${beforeId}`)
      .accessibilityText(beforeId === null ? '移到正文末尾' : `移到区块之前：${this.blocks.find(block => block.id === beforeId)?.source.split('\n', 1)[0] ?? ''}`)
      .onClick((): void => { this.placeBlock(beforeId) })
  }

  blockFor(slot: TaskContentSlot): CoreContentBlock {
    // 删除时 ArkUI 可能在卸载旧行前再刷新一次其属性。
    return this.slots.find(current => current.key === slot.key)?.block ?? slot.block
  }
  indexFor(key: string): number { return this.slots.findIndex(slot => slot.key === key) }

  @Builder
  readChecklist(index: () => number) {
    TaskChecklistBlock({ items: this.blocks[index()].items, readonly: this.readonly, ownerKey: this.ownerKey, blockId: this.blocks[index()].id,
      tree: this.treeFor(this.blocks[index()].id), processor: this.internalLinkProcessor, revision: this.revision }).width('100%')
  }

  treeFor(id: string): CoreContentNode | undefined { return this.contentTree?.find(node => node.id === id) }

  @Builder
  nativeBlock(slot: TaskContentSlot, edit: () => void) {
    TaskNativeContent({ nodes: this.contentTree?.filter(node => node.id === this.blockFor(slot).id) ?? [], readonly: this.readonly, disabled: this.disabled,
      revision: this.revision, processor: this.internalLinkProcessor, editor: this.editor, linkEditor: this.linkEditor,
      activateParagraph: this.blockFor(slot).paragraph ? edit : undefined,
      begin: (): Promise<boolean> => this.begin(this.blockFor(slot)), write: this.writeNode, toggle: this.toggle,
      editingChanged: this.editingChanged, linkEditingChanged: this.linkEditingChanged })
  }

  build() {
    Column({ space: this.projectReading ? 0 : 12 }) {
      if (this.movingId) {
        Row({ space: 8 }) {
          Text(this.savingMove ? '正在移动…' : '点插入线选择位置').fontSize(14).fontColor(UiColor.text).layoutWeight(1)
          Button('取消').height(44).fontSize(14).backgroundColor(Color.Transparent).fontColor(UiColor.primary)
            .enabled(!this.savingMove).onClick((): void => { this.cancelMove() })
        }.width('100%')
      }
      if (!this.readonly && this.blocks.length === 0) {
        TaskBlockView({ block: this.emptyBlock, emptyBody: true, placeholder: '段落', disabled: this.disabled,
          revision: this.revision, ownerKey: this.ownerKey, editor: this.editor, linkEditor: this.linkEditor,
          begin: (_block: CoreContentBlock): Promise<boolean> => this.beginEmpty(),
          save: (_block: CoreContentBlock, source: string): Promise<boolean> => this.saveFirstParagraph(source),
          followParagraph: (finish: () => Promise<boolean>): Promise<void> => this.appendFollowingParagraph('', finish),
          editingChanged: this.editingChanged }).width('100%')
      }
      ForEach(this.slots, (slot: TaskContentSlot) => {
        if (this.validMoveGap(this.indexFor(slot.key))) { this.moveGap(this.blockFor(slot).id) }
        Column() {
          if (this.blockFor(slot).kind === 'checklist' ||
            (this.interactiveLists && this.blockFor(slot).kind === 'list' && this.blockFor(slot).items.length > 0 &&
              this.treeFor(this.blockFor(slot).id))) {
            TaskBlockView({ internalLinkProcessor: this.internalLinkProcessor, block: this.blockFor(slot), readonly: this.readonly, disabled: this.disabled,
              revision: this.revision, projectReading: this.projectReading, nativeChecklist: true, checklistEditing: this.checklistEditing,
              contentBackground: this.contentBackground, ownerKey: this.ownerKey, editor: this.editor, linkEditor: this.linkEditor,
              insertBelow: true, nextBlock: this.blocks[this.indexFor(slot.key) + 1],
              allowMove: !!this.moveContent && !!this.moveVersion && this.blocks.length > 1,
              move: (block: CoreContentBlock): Promise<void> => this.selectMove(block),
              followRequest: this.followKey === slot.key ? this.followRequest : 0,
              followParagraph: (finish: () => Promise<boolean>): Promise<void> => this.appendFollowingParagraph(slot.key, finish),
              followChecklist: (finish: () => Promise<boolean>): Promise<void> => this.appendFollowingChecklistItem(slot.key, finish),
              placeholder: '列表', readContent: (): void => { this.checklist((): number => this.indexFor(slot.key)) }, begin: this.begin, save: this.save,
              editingChanged: this.editingChanged }).width('100%')
          } else if (this.treeFor(this.blockFor(slot).id)) {
            TaskBlockView({ block: this.blockFor(slot), readonly: this.readonly, disabled: this.disabled,
              revision: this.revision, nativeChecklist: true, checklistEditing: this.checklistEditing,
              contentBackground: this.contentBackground, ownerKey: this.ownerKey,
              insertBelow: this.blockFor(slot).paragraph || this.blockFor(slot).kind === 'list',
              allowMove: !!this.moveContent && !!this.moveVersion && this.blocks.length > 1 &&
                (this.blockFor(slot).paragraph || this.blockFor(slot).kind === 'list'),
              move: (block: CoreContentBlock): Promise<void> => this.selectMove(block),
              nextBlock: this.blocks[this.indexFor(slot.key) + 1],
              followRequest: this.followKey === slot.key ? this.followRequest : 0,
              followParagraph: (finish: () => Promise<boolean>): Promise<void> => this.appendFollowingParagraph(slot.key, finish),
              followChecklist: (finish: () => Promise<boolean>): Promise<void> => this.appendFollowingChecklistItem(slot.key, finish),
              placeholder: this.blockFor(slot).paragraph ? '段落' : '正文',
              editor: this.editor, linkEditor: this.linkEditor, nativeContent: (edit: () => void): void => { this.nativeBlock(slot, edit) },
              begin: this.begin, save: this.save, editingChanged: this.editingChanged }).width('100%')
          } else {
            TaskBlockView({ internalLinkProcessor: this.internalLinkProcessor, block: this.blockFor(slot), readonly: this.readonly, disabled: this.disabled, revision: this.revision, projectReading: this.projectReading,
              checklistEditing: this.checklistEditing, contentBackground: this.contentBackground, ownerKey: this.ownerKey, editor: this.editor, linkEditor: this.linkEditor,
              followRequest: this.followKey === slot.key ? this.followRequest : 0,
              followParagraph: (finish: () => Promise<boolean>): Promise<void> => this.appendFollowingParagraph(slot.key, finish),
              nextBlock: this.blocks[this.indexFor(slot.key) + 1],
              placeholder: this.blockFor(slot).paragraph ? '段落' : '正文',
              begin: this.begin, save: this.save, changeLink: this.changeLink, editingChanged: this.editingChanged,
              linkEditingChanged: this.linkEditingChanged }).width('100%')
          }
        }.width('100%').enabled(!this.movingId)
          .outline({ width: this.blockFor(slot).id === this.movingId ? 1 : 0, color: UiColor.primary, radius: 4 })
          .margin({ top: this.projectReading && !this.movingId ? projectContentGap(this.blocks, this.indexFor(slot.key)) : 0 })
      }, (slot: TaskContentSlot): string => slot.key)
      if (this.validMoveGap(this.blocks.length)) { this.moveGap(null) }
    }.width('100%')
  }
}
