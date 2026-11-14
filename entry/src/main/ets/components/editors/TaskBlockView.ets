import { InternalLinkProcessor } from '../../ui/InternalLinkProcessor'
import { CoreContentBlock, CoreTextLink, CoreLinkValue } from '../../services/NativeCoreService'
import { OrgContentView } from '../OrgContentView'
import { LinkEditController } from '../LinkView'
import { TaskBlockController } from '../../ui/TaskBlockController'
import { UiColor, UiSize } from '../../ui/Theme'
import { PopupMenu, PopupMenuItem } from '../controls/PopupMenu'
import { pasteboard } from '@kit.BasicServicesKit'
import { display } from '@kit.ArkUI'

// 正文区块共用菜单与原文编辑外壳；清单阅读保留原生交互，只读仍可拷贝。
@Component
export struct TaskBlockView {
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop block: CoreContentBlock
  @Prop @Watch('readonlyChanged') readonly: boolean = false
  @Prop projectReading: boolean = false
  @Prop disabled: boolean = false
  @Prop revision: string = ''
  @Prop contentBackground: string = UiColor.taskCard
  @Prop ownerKey: string = ''
  @Prop placeholder: string = '文本'
  @Prop nativeChecklist: boolean = false
  @Prop checklistEditing: boolean = false
  @BuilderParam readContent: () => void = this.emptyContent
  editor: TaskBlockController = new TaskBlockController()
  linkEditor: LinkEditController = new LinkEditController()
  begin: (block: CoreContentBlock) => Promise<boolean> = async () => true
  save: (block: CoreContentBlock, source: string) => Promise<boolean> = async () => false
  changeLink: ((block: CoreContentBlock, link: CoreTextLink, value: CoreLinkValue | null) => Promise<void>) | undefined = undefined
  editingChanged: (editing: boolean) => void = () => {}
  linkEditingChanged: (editing: boolean) => void = () => {}
  @State editing: boolean = false
  @State draft: string = ''
  @State saving: boolean = false
  @State menuVisible: boolean = false
  @State menuX: number = 0
  @State menuY: number = 0
  @State menuWidth: number = 320
  private menuBlock: CoreContentBlock | undefined = undefined
  private menuRevision: string = ''
  private preparing: boolean = false
  private original: CoreContentBlock | undefined = undefined
  private inputKey: string = ''
  private alive: boolean = true
  private pending: Promise<boolean> | undefined = undefined

  aboutToAppear() { this.alive = true; this.inputKey = `block_${this.ownerKey}_${this.getUniqueId()}` }
  aboutToDisappear() { this.alive = false; this.menuVisible = false; this.editor.release(this.inputKey); if (this.editing) this.editingChanged(false) }

  readonlyChanged() { this.menuVisible = false; if (this.readonly) this.cancel() }

  async prepare(block: CoreContentBlock, revision: string): Promise<boolean> {
    if (!this.alive || this.readonly || this.disabled || this.editing || this.saving || revision !== this.revision) return false
    if (!await this.editor.finish() || !await this.linkEditor.finish() || revision !== this.revision) return false
    if (!await this.begin(block)) return false
    return this.alive && !this.readonly && !this.disabled && revision === this.revision
      && block.id === this.block.id && block.source === this.block.source
  }

  async edit(block: CoreContentBlock = this.block, revision: string = this.revision) {
    if (this.preparing) return
    this.menuVisible = false
    this.preparing = true
    try {
      if (!await this.prepare(block, revision)) return
      this.original = block
      this.draft = block.source
      if (!await this.editor.begin(this.inputKey, async (): Promise<boolean> => this.finish(), (): void => { this.cancel() })) return
      this.editing = true; this.editingChanged(true)
    } finally { this.preparing = false }
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
    if (!block || this.preparing) return false
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

  menuItems(): PopupMenuItem[] {
    const items: PopupMenuItem[] = [{ title: '拷贝', icon: $r('app.media.ui_link_copy'), action: (): void => { this.copySelected() } }]
    if (!this.readonly) {
      items.push({ title: '编辑', icon: $r('app.media.ui_link_edit'), action: (): void => {
        if (this.menuBlock) this.edit(this.menuBlock, this.menuRevision)
      } })
      items.push({ title: '删除', icon: $r('app.media.ui_delete'), dangerous: true, action: (): void => { this.deleteSelected() } })
    }
    return items
  }

  async finish(): Promise<boolean> {
    if (this.pending) return this.pending
    if (!this.editing || !this.original) return true
    if (this.readonly || this.disabled) return false
    const block = this.original
    const source = this.draft
    this.saving = true
    this.pending = source === block.source ? Promise.resolve(true) : this.save(block, source)
    try {
      if (!await this.pending) return false
      if (this.alive) { this.editing = false; this.editingChanged(false) }
      this.editor.release(this.inputKey)
      return true
    } finally { this.pending = undefined; if (this.alive) this.saving = false }
  }

  cancel() {
    if (this.saving) return
    this.editing = false; this.editingChanged(false); this.editor.release(this.inputKey)
  }

  @Builder
  emptyContent() {}

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

  build() {
    Column({ space: 4 }) {
      if (this.editing) {
        TextArea({ text: this.draft, placeholder: this.placeholder }).id(this.inputKey).defaultFocus(true)
          .width('100%').height('auto').minLines(1).maxLines(1000).fontSize(14).fontColor(UiColor.text)
          .backgroundColor(Color.Transparent).padding(0).borderRadius(0).enabled(!this.readonly && !this.saving && !this.disabled)
          .onChange((value: string): void => { this.draft = value })
        Row({ space: 12 }) {
          Button('取消').height(36).fontColor(UiColor.secondary).backgroundColor(Color.Transparent)
            .enabled(!this.saving).onClick((): void => { this.cancel() })
          Button('保存').height(36).fontColor(UiColor.primary).backgroundColor(Color.Transparent)
            .enabled(!this.readonly && !this.saving && !this.disabled).onClick((): void => { this.finish() })
        }.width('100%').justifyContent(FlexAlign.End)
      } else if (this.nativeChecklist) {
        Column() { this.readContent() }.width('100%')
          .onTouch((event: TouchEvent): void => {
            if (event.type === TouchType.Down || event.type === TouchType.Up) LinkEditController.protectInteraction()
          })
          .gesture(LongPressGesture({ repeat: false, duration: 500 }).onAction((event: GestureEvent): void => {
            this.openMenu(event.fingerList[0]?.localX ?? 0, event.fingerList[0]?.localY ?? 0)
          }))
      } else {
        OrgContentView({ internalLinkProcessor: this.internalLinkProcessor, fragment: this.block.html, revision: this.revision, embedded: true, embeddedPadding: 0,
          projectReading: this.projectReading,
          editable: !this.readonly && !this.disabled && this.changeLink !== undefined,
          linkEditor: this.linkEditor, linkEditingChanged: this.linkEditingChanged,
          changeLink: this.changeLink ? (link: CoreTextLink, value: CoreLinkValue | null): Promise<void> => this.changeLink!(this.block, link, value) : undefined,
          contentBackground: this.contentBackground, activate: this.readonly ? undefined : (): void => { this.edit() },
          contextMenu: (x: number, y: number): void => { this.openMenu(x, y) } }).width('100%')
      }
      this.menuAnchor()
    }.width('100%').outline({ width: this.menuVisible ? 1 : 0, color: '#597C75', radius: 4 })
  }
}
