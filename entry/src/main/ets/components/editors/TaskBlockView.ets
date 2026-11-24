import { InternalLinkProcessor } from '../../ui/InternalLinkProcessor'
import { CoreContentBlock, CoreTextLink, CoreLinkValue } from '../../services/NativeCoreService'
import { OrgContentView } from '../OrgContentView'
import { LinkEditController } from '../LinkView'
import { TaskBlockController } from '../../ui/TaskBlockController'
import { UiColor, UiSize } from '../../ui/Theme'
import { PopupMenu, PopupMenuItem } from '../controls/PopupMenu'
import { pasteboard } from '@kit.BasicServicesKit'
import { display } from '@kit.ArkUI'
import { ChecklistFocusFrame, TaskChecklistBlock } from './TaskChecklistBlock'
import { TaskInlineFocus } from '../../ui/TaskInlineFocus'

// 正文区块共用菜单与原文编辑外壳；清单阅读保留原生交互，只读仍可拷贝。
@Component
export struct TaskBlockView {
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop block: CoreContentBlock
  @Prop @Watch('readonlyChanged') readonly: boolean = false
  @Prop projectReading: boolean = false
  @Prop disabled: boolean = false
  @Prop @Watch('closeParagraphSwipe') revision: string = ''
  @Prop contentBackground: string = UiColor.taskCard
  @Prop ownerKey: string = ''
  @Prop placeholder: string = '文本'
  @Prop emptyBody: boolean = false
  @Prop @Watch('followRequested') followRequest: number = 0
  @Prop nativeChecklist: boolean = false
  @Prop checklistEditing: boolean = false
  @Prop insertBelow: boolean = false
  @Prop allowMove: boolean = false
  @Prop nextBlock: CoreContentBlock | undefined = undefined
  @BuilderParam readContent: () => void = this.emptyContent
  @BuilderParam nativeContent: (edit: () => void) => void = this.emptyNativeContent
  editor: TaskBlockController = new TaskBlockController()
  linkEditor: LinkEditController = new LinkEditController()
  begin: (block: CoreContentBlock) => Promise<boolean> = async () => true
  move: (block: CoreContentBlock) => Promise<void> = async () => {}
  save: (block: CoreContentBlock, source: string) => Promise<boolean> = async () => false
  followParagraph: ((save: () => Promise<boolean>) => Promise<void>) | undefined = undefined
  followChecklist: ((save: () => Promise<boolean>) => Promise<void>) | undefined = undefined
  changeLink: ((block: CoreContentBlock, link: CoreTextLink, value: CoreLinkValue | null) => Promise<void>) | undefined = undefined
  editingChanged: (editing: boolean) => void = () => {}
  linkEditingChanged: (editing: boolean) => void = () => {}
  @State editing: boolean = false
  @State draft: string = ''
  @State saving: boolean = false
  @State adding: boolean = false
  @State addingList: boolean = false
  @State menuVisible: boolean = false
  @State menuX: number = 0
  @State menuY: number = 0
  @State menuWidth: number = 320
  @State private paragraphHeight: number = 20
  private menuBlock: CoreContentBlock | undefined = undefined
  private menuRevision: string = ''
  private swipedBlock: CoreContentBlock | undefined = undefined
  private swipeRevision: string = ''
  private paragraphScroller: ListScroller = new ListScroller()
  private preparing: boolean = false
  private original: CoreContentBlock | undefined = undefined
  private editRevision: string = ''
  private inputKey: string = ''
  private alive: boolean = true
  private pending: Promise<boolean> | undefined = undefined
  private handledFollow: number = 0
  private submitting: boolean = false
  private inputController: TextAreaController = new TextAreaController()
  private checklistFocus: TaskInlineFocus = new TaskInlineFocus(
    (callback: () => void) => { this.getUIContext().postFrameCallback(new ChecklistFocusFrame(callback)) },
    (key: string) => { this.getUIContext().getFocusController().requestFocus(key) })

  aboutToAppear() {
    this.alive = true
    this.inputKey = `block_${this.ownerKey}_${this.getUniqueId()}`
    this.followRequested()
  }
  aboutToDisappear() {
    this.alive = false
    this.menuVisible = false
    this.checklistFocus.dispose()
    this.editor.release(this.inputKey)
    if (this.editing) this.editingChanged(false)
  }

  readonlyChanged() { this.menuVisible = false; if (this.readonly) this.cancel() }

  followRequested(): void {
    if (!this.inputKey || !this.followRequest || this.followRequest === this.handledFollow) return
    this.handledFollow = this.followRequest
    this.edit(this.block, this.revision, 'paragraph')
  }

  async prepare(block: CoreContentBlock, revision: string): Promise<boolean> {
    if (!this.alive || this.readonly || this.disabled || this.editing || this.saving || revision !== this.revision) return false
    if (!await this.editor.finish() || !await this.linkEditor.finish() || revision !== this.revision) return false
    if (!await this.begin(block)) return false
    return this.alive && !this.readonly && !this.disabled && revision === this.revision
      && block.id === this.block.id && block.source === this.block.source
  }

  async edit(block: CoreContentBlock = this.block, revision: string = this.revision, addition: string = '') {
    if (this.preparing) return
    this.menuVisible = false
    this.preparing = true
    try {
      if (!await this.prepare(block, revision)) return
      this.original = block
      this.editRevision = revision
      this.adding = addition !== ''
      this.addingList = addition === 'list'
      this.draft = this.adding ? '' : block.source
      if (!await this.editor.begin(this.inputKey, async (): Promise<boolean> => this.finish(), (): void => { this.cancel() })) return
      this.editing = true; this.editingChanged(true)
      if (this.addingList) this.checklistFocus.request(`inline_new_check_${this.inputKey}`)
    } finally { this.preparing = false }
  }

  async editCurrent(): Promise<void> {
    const selected = this.block
    if (!this.alive || this.readonly || !await this.editor.finish()) return
    if (this.block.kind !== selected.kind || this.block.source !== selected.source) return
    await this.edit()
  }

  openMenu(x: number, y: number) {
    if (!this.alive || this.disabled || this.editing || this.checklistEditing || this.saving || this.preparing) return
    LinkEditController.protectInteraction()
    this.menuBlock = this.block; this.menuRevision = this.revision
    this.menuX = Math.max(0, x); this.menuY = Math.max(0, y)
    try { this.menuWidth = this.getUIContext().px2vp(display.getDefaultDisplaySync().width) - 32 } catch (_) {}
    this.menuVisible = true
  }

  notify(message: string) {
    try { if (this.alive) this.getUIContext().getPromptAction().showToast({ message }) } catch (_) {}
  }

  async copySelected() {
    const block = this.menuBlock
    this.menuVisible = false
    if (!block) return
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, block.source))
      this.notify('区块已拷贝')
    } catch (_) { this.notify('拷贝失败，请重试') }
  }

  async deleteSelected(): Promise<boolean> {
    const block = this.menuBlock
    const revision = this.menuRevision
    this.menuVisible = false
    return block ? this.deleteBlock(block, revision) : false
  }

  private async deleteBlock(block: CoreContentBlock, revision: string): Promise<boolean> {
    if (this.preparing) return false
    this.preparing = true
    let started: boolean = false
    try {
      if (!await this.prepare(block, revision)) return false
      this.saving = true; started = true; this.editingChanged(true)
      const saved = await this.save(block, '')
      if (!saved) this.notify('删除失败，请确认文件版本后重试')
      return saved
    } finally {
      this.preparing = false; this.saving = false
      if (started) this.editingChanged(false)
    }
  }

  closeParagraphSwipe(): void {
    if (!this.swipedBlock) return
    try { this.paragraphScroller.closeAllSwipeActions() }
    catch (_) { this.swipedBlock = undefined }
  }

  private paragraphOffsetChanged(offset: number): void {
    if (offset < 0 && !this.swipedBlock) {
      this.swipedBlock = this.block
      this.swipeRevision = this.revision
    } else if (offset === 0) this.swipedBlock = undefined
  }

  private async deleteSwipedParagraph(): Promise<boolean> {
    const block = this.swipedBlock
    const revision = this.swipeRevision
    LinkEditController.protectInteraction()
    this.closeParagraphSwipe()
    return block ? this.deleteBlock(block, revision) : false
  }

  async moveSelected(): Promise<void> {
    const block = this.menuBlock
    const revision = this.menuRevision
    this.menuVisible = false
    if (!block || !this.allowMove || this.preparing) return
    this.preparing = true
    try {
      if (await this.prepare(block, revision)) await this.move(block)
    } finally { this.preparing = false }
  }

  menuItems(): PopupMenuItem[] {
    const items: PopupMenuItem[] = [{ title: '拷贝', icon: $r('app.media.ui_link_copy'), action: (): void => { this.copySelected() } }]
    if (!this.readonly) {
      items.push({ title: '编辑', icon: $r('app.media.ui_link_edit'), action: (): void => {
        if (this.menuBlock) this.edit(this.menuBlock, this.menuRevision)
      } })
      if (this.allowMove) {
        items.push({ title: '移动…', icon: $r('app.media.ui_move_to'), action: (): void => { this.moveSelected() } })
      }
      if (this.insertBelow) {
        items.push({ title: '在下方添加段落', action: (): void => {
          if (this.menuBlock) this.edit(this.menuBlock, this.menuRevision, 'paragraph')
        } })
        items.push({ title: '在下方添加列表', action: (): void => {
          if (this.menuBlock) this.edit(this.menuBlock, this.menuRevision, 'list')
        } })
      }
      items.push({ title: '删除', icon: $r('app.media.ui_delete'), dangerous: true, action: (): void => { this.deleteSelected() } })
    }
    return items
  }

  private editedSource(block: CoreContentBlock): string {
    if (!this.adding) return this.draft
    const draft = this.addingList ? this.draft.replace(/[\r\n]+/g, ' ').trim() : this.draft.replace(/[\r\n]+$/, '')
    if (!draft.trim()) return block.source
    const afterList = block.kind === 'list' || block.kind === 'checklist'
    const separator = this.addingList && afterList ? '\n\n\n' : '\n\n'
    const next = this.nextBlock
    const nextList = next?.kind === 'list' || next?.kind === 'checklist'
    const gap = this.addingList && nextList ? 2 : 1
    const suffix = next ? '\n'.repeat(Math.max(0, gap - next.blankLinesBefore)) : ''
    const content = this.addingList ? `- [ ] ${draft}` : draft
    return block.source + separator + content + suffix
  }

  async finish(): Promise<boolean> {
    if (this.pending) return this.pending
    if (!this.editing || !this.original) return true
    if (this.readonly || this.disabled || this.editRevision !== this.revision) return false
    const block = this.original
    const source = this.editedSource(block)
    this.saving = true
    this.pending = source === block.source ? Promise.resolve(true) : this.save(block, source)
    try {
      if (!await this.pending) return false
      if (this.alive) { this.editing = false; this.editingChanged(false) }
      this.editor.release(this.inputKey)
      return true
    } finally { this.pending = undefined; if (this.alive) this.saving = false }
  }

  async submitDraft(): Promise<void> {
    if (this.pending || this.submitting || !this.editing) return
    this.submitting = true
    try {
      const follow = this.addingList ? this.followChecklist : this.followParagraph
      if (follow && this.draft.trim()) {
        await follow((): Promise<boolean> => this.finish())
      } else {
        await this.finish()
      }
    } finally { this.submitting = false }
  }

  cancel() {
    if (this.saving) return
    this.checklistFocus.cancel()
    this.editing = false; this.editingChanged(false); this.editor.release(this.inputKey)
  }

  @Builder
  emptyContent() {}

  @Builder
  emptyNativeContent(_edit: () => void) { this.readContent() }

  @Builder
  blockMenu() {
    Column() {
      PopupMenu({ items: this.menuItems(), maximumWidth: this.menuWidth, disabled: this.disabled || this.saving,
        activate: (item: PopupMenuItem): void => { item.action() } })
    }.backgroundColor(UiColor.menu).borderRadius(UiSize.menuRadius)
      .border({ width: UiSize.menuBorder, color: UiColor.menuOutline }).clip(true)
  }

  @Builder
  menuAnchor() {
    Row().width(1).height(1).position({ x: this.menuX, y: this.menuY })
      .bindPopup(this.menuVisible, { builder: this.blockMenu(), placement: Placement.Top,
        targetSpace: 6, enableArrow: true, popupColor: UiColor.menu, backgroundBlurStyle: BlurStyle.NONE,
        mask: { color: Color.Transparent }, focusable: false, autoCancel: true,
        onStateChange: (event): void => { this.menuVisible = event.isVisible } })
  }

  @Builder
  newChecklist() {
    TaskChecklistBlock({ adding: true, newText: this.draft, ownerKey: this.inputKey, blockId: 'new',
      disabled: this.disabled || this.saving,
      newChanged: (text: string): void => { this.draft = text },
      save: (next: boolean): void => {
        if (next) this.submitDraft()
        else if (!this.submitting) this.finish()
      },
      inputAppeared: (id: string): void => { this.checklistFocus.appeared(id) },
      inputDisappeared: (id: string): void => { this.checklistFocus.disappeared(id) },
      inputVisible: (id: string): void => { this.checklistFocus.visible(id) } }).width('100%')
  }

  @Builder
  reading() {
    if (this.nativeChecklist) {
      Column() { this.nativeContent((): void => { this.editCurrent() }) }.width('100%')
        .onTouch((event: TouchEvent): void => {
          if (event.type === TouchType.Down || event.type === TouchType.Up) LinkEditController.protectInteraction()
        })
        .gesture(LongPressGesture({ repeat: false, duration: 500 }).onAction((event: GestureEvent): void => {
          this.openMenu(event.fingerList[0]?.localX ?? 0, event.fingerList[0]?.localY ?? 0)
        }))
    } else {
      OrgContentView({ internalLinkProcessor: this.internalLinkProcessor, fragment: this.block.html, revision: this.revision, reloadOnRevision: false, embedded: true, embeddedPadding: 0,
        projectReading: this.projectReading, horizontalParentFirst: !this.projectReading,
        editable: !this.readonly && !this.disabled && this.changeLink !== undefined,
        linkEditor: this.linkEditor, linkEditingChanged: this.linkEditingChanged,
        changeLink: this.changeLink ? (link: CoreTextLink, value: CoreLinkValue | null): Promise<void> => this.changeLink!(this.block, link, value) : undefined,
        contentBackground: this.contentBackground, activate: this.readonly ? undefined : (): void => { this.editCurrent() },
        contextMenu: (x: number, y: number): void => { this.openMenu(x, y) } }).width('100%')
    }
  }

  @Builder
  paragraphDeleteButton() {
    Button({ type: ButtonType.Normal }) {
      Image($r('app.media.ui_delete')).width(18).height(18)
    }.width(44).height(Math.min(44, this.paragraphHeight)).padding(0).borderRadius(6)
      .backgroundColor('#513A40').accessibilityText('删除段落')
      .enabled(!this.disabled && !this.saving).onClick((): void => { this.deleteSwipedParagraph() })
  }

  @Builder
  swipeParagraph() {
    List({ scroller: this.paragraphScroller }) {
      ListItem() {
        Column() { this.reading() }.width('100%').onAreaChange((_old: Area, area: Area): void => {
          const height = Math.ceil(Number(area.height))
          if (height > 0 && height !== this.paragraphHeight) this.paragraphHeight = height
        })
      }.swipeAction(this.disabled || this.editing || this.checklistEditing || this.saving ? {} : {
        end: this.paragraphDeleteButton(), edgeEffect: SwipeEdgeEffect.None,
        onOffsetChange: (offset: number): void => { this.paragraphOffsetChanged(offset) }
      })
    }.width('100%').height(this.paragraphHeight).scrollBar(BarState.Off).enableScrollInteraction(false)
  }

  @Builder
  input() {
    Column({ space: 4 }) {
      TextArea({ text: this.draft, controller: this.inputController,
        placeholder: this.adding ? '段落' : this.placeholder })
        .id(this.inputKey).defaultFocus(true)
        .width('100%').height('auto').minLines(1).maxLines(1000).fontSize(14).fontColor(UiColor.text)
        .backgroundColor(Color.Transparent).padding(0).borderRadius(0).enabled(!this.readonly && !this.saving && !this.disabled)
        .enterKeyType(this.emptyBody || this.adding || this.block.paragraph ? EnterKeyType.Next : EnterKeyType.NEW_LINE)
        .onSubmit((key: EnterKeyType, event: SubmitEvent): void => {
          if (key !== EnterKeyType.Next) return
          event.keepEditableState()
          this.submitDraft()
        })
        .onChange((value: string): void => { this.draft = value })
        .onBlur((): void => { if (!this.submitting) this.finish() })
        .onAppear((): void => {
          const context = this.getUIContext()
          context.postFrameCallback(new ChecklistFocusFrame((): void => {
            if (!this.alive || !this.editing || this.disabled) return
            try {
              context.getFocusController().requestFocus(this.inputKey)
              this.inputController.caretPosition(this.draft.length)
            } catch (_) { /* 控件移出可见区时仍保留草稿。 */ }
          }))
        })
    }.width('100%').onClick((): void => { LinkEditController.protectInteraction() })
  }

  build() {
    Column({ space: 4 }) {
      if (this.editing && !this.adding) {
        this.input()
      } else if (this.emptyBody) {
        Text('添加正文').fontSize(14).fontColor(UiColor.disabled).width('100%').constraintSize({ minHeight: 24 })
          .enabled(!this.readonly && !this.disabled)
          .onClick((): void => { this.editCurrent() })
      } else if (this.block.paragraph && !this.readonly) {
        this.swipeParagraph()
      } else {
        this.reading()
      }
      if (this.editing && this.adding) {
        if (this.addingList) { this.newChecklist() }
        else { this.input() }
      }
      this.menuAnchor()
    }.width('100%').outline({ width: this.menuVisible ? 1 : 0, color: '#597C75', radius: 4 })
  }
}
