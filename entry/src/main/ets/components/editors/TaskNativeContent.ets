import { localizedText } from '../../ui/LocalizedText'
import { DraftInputFrame, DraftLinkAction, DraftLinkSelection } from './DraftLinkAction'
import { CoreContentBlockChange, CoreContentNode, CoreContentInline, CoreTaskChecklistChange, CoreTitlePart,
  CoreTextLink, CoreLinkValue } from '../../services/NativeCoreService'
import { InternalLinkProcessor } from '../../ui/InternalLinkProcessor'
import { LinkEditController, LinkView } from '../LinkView'
import { TaskBlockController } from '../../ui/TaskBlockController'
import { UiColor, UiSize } from '../../ui/Theme'

@Component
export struct TaskNativeContent {
  @Prop nodes: CoreContentNode[] = []
  @Prop readonly: boolean = false
  @Prop disabled: boolean = false
  @Prop completed: boolean = false
  @Prop revision: string = ''
  @Prop itemId: string = ''
  processor: InternalLinkProcessor | undefined = undefined
  editor: TaskBlockController = new TaskBlockController()
  linkEditor: LinkEditController = new LinkEditController()
  begin: () => Promise<boolean> = async () => false
  write: (change: CoreContentBlockChange) => Promise<void> = async () => {}
  toggle: (change: CoreTaskChecklistChange) => void = () => {}
  activateParagraph: ((node: CoreContentNode) => void) | undefined = undefined
  editingChanged: (editing: boolean) => void = () => {}
  linkEditingChanged: (editing: boolean) => void = () => {}
  @State editNode: CoreContentNode | undefined = undefined
  @State draft: string = ''
  @State addingParagraph: boolean = false
  @State saving: boolean = false
  @State error: string = ''
  private editKey: string = ''
  private editVersion: string = ''
  private inputController: TextAreaController = new TextAreaController()
  private linkSelection: DraftLinkSelection = new DraftLinkSelection()
  private pending: Promise<boolean> | undefined = undefined

  aboutToAppear(): void { this.editKey = `native_body_${this.getUniqueId()}` }
  aboutToDisappear(): void {
    this.editor.release(this.editKey)
    if (this.editNode) this.editingChanged(false)
  }

  private parts(node: CoreContentNode): CoreTitlePart[] {
    return (node.parts ?? []).map((part: CoreContentInline): CoreTitlePart => ({
      text: part.text, href: part.href, isLink: part.isLink, count: null, link: part.link, styles: part.styles
    }))
  }

  private async startEdit(node: CoreContentNode, append: boolean = false): Promise<void> {
    if (this.readonly || this.disabled || this.saving || this.editNode) return
    const version = this.revision
    if (!await this.editor.finish() || !await this.linkEditor.finish() || !await this.begin() || version !== this.revision) return
    if (!await this.editor.begin(this.editKey, (): Promise<boolean> => this.finish(), (): void => { this.cancel() })) return
    this.draft = append ? '' : node.source
    this.linkSelection.reset()
    this.editVersion = version
    this.error = ''
    this.addingParagraph = append
    this.editNode = node
    this.editingChanged(true)
  }

  private cancel(): void {
    this.editNode = undefined
    this.editor.release(this.editKey)
    this.editingChanged(false)
  }

  private async finish(): Promise<boolean> {
    if (this.pending) return this.pending
    const node = this.editNode
    if (!node) return true
    if (this.saving || this.linkSelection.busy) return false
    if (this.editVersion !== this.revision) {
      this.error = localizedText($r('app.string.text_the_contents_have_changed_please_reload_the'))
      return false
    }
    if ((!this.addingParagraph && this.draft === node.source) || (this.addingParagraph && !this.draft.trim())) {
      this.cancel()
      return true
    }
    this.saving = true
    this.pending = this.saveDraft(node)
    try {
      return await this.pending
    } finally { this.pending = undefined; this.saving = false }
  }

  private async saveDraft(node: CoreContentNode): Promise<boolean> {
    try {
      await this.write({ type: this.addingParagraph ? 'insertParagraph' : 'replaceText', id: this.containerId(node), source: this.draft })
      this.cancel()
      return true
    } catch (error) {
      this.error = (error as Error).message || localizedText($r('app.string.text_save_failed_please_try_again'))
      return false
    }
  }

  private containerId(node: CoreContentNode): string { return this.addingParagraph && node.kind === 'list' ? `list:${node.id}` : node.id }

  private async changeLink(node: CoreContentNode, link: CoreTextLink, value: CoreLinkValue | null): Promise<void> {
    const version = this.revision
    if (!await this.begin() || version !== this.revision) throw new Error(localizedText($r('app.string.text_content_has_changed_please_reload_and_edit')))
    await this.write({ type: 'treeLink', id: node.id, link, value })
  }

  private activate(node: CoreContentNode): void {
    if (node.kind === 'paragraph' && this.nodes[0]?.id === node.id && this.activateParagraph) {
      this.activateParagraph(node)
    } else {
      this.startEdit(node)
    }
  }

  private focusDraft(): void {
    const node = this.editNode
    const context = this.getUIContext()
    context.postFrameCallback(new DraftInputFrame((): void => {
      if (!node || this.editNode !== node || this.linkSelection.busy) return
      try {
        context.getFocusController().requestFocus(this.editKey)
        this.inputController.caretPosition(this.draft.length)
      } catch (_) {
        // 视口移动后可点按输入框继续编辑。
      }
    }))
  }

  @Builder
  editorContent(node: CoreContentNode, itemId: string) {
    Column({ space: 4 }) {
      TextArea({ text: this.draft, controller: this.inputController,
        placeholder: node.kind === 'cell' ? localizedText($r('app.string.text_cells')) : localizedText($r('app.string.text_paragraph')) }).id(this.editKey).defaultFocus(true)
        .width('100%').height('auto').minLines(1)
        .fontSize(node.kind === 'cell' ? 14 : itemId ? UiSize.listItemFont : UiSize.paragraphFont)
        .lineHeight(node.kind === 'cell' ? 0 : itemId ? UiSize.listItemLineHeight : UiSize.paragraphLineHeight)
        .fontColor(UiColor.text)
        .backgroundColor(UiColor.field).enabled(!this.saving)
        .onChange((value: string): void => { this.draft = value })
        .onBlur((): void => { if (!this.linkSelection.busy) this.finish() })
        .onAppear((): void => { this.focusDraft() })
        .enterKeyType(EnterKeyType.NEW_LINE)
        .onTextSelectionChange((start: number, end: number): void => {
          this.linkSelection.update(start, end)
        })
      DraftLinkAction({ source: this.draft, disabled: this.saving || this.editVersion !== this.revision,
        inputId: this.editKey, editor: this.linkEditor, selection: this.linkSelection,
        write: (source: string): void => { this.draft = source },
        select: (start: number, end: number): void => {
          this.inputController.setTextSelection(start, end, { menuPolicy: MenuPolicy.HIDE })
        } })
      if (!this.addingParagraph && itemId) {
        Row() {
            Button($r('app.string.text_add_notes')).height(36).fontSize(13).fontColor(UiColor.primary).backgroundColor(Color.Transparent).focusable(false)
              .enabled(!this.saving && this.draft === node.source)
              .onClick((): void => {
                if (this.linkSelection.busy) return
                this.cancel()
                this.startEdit({ id: itemId, kind: 'item', source: '', blankLinesBefore: 0 }, true)
              })
        }.width('100%').justifyContent(FlexAlign.End)
      }
      if (this.error) { Text(this.error).fontSize(12).fontColor(UiColor.error) }
    }.width('100%').alignItems(HorizontalAlign.Start)
      .onClick((): void => { LinkEditController.protectInteraction() })
  }

  @Builder
  inline(node: CoreContentNode, checked: boolean, itemId: string = '') {
    if (this.editNode?.id === node.id) {
      this.editorContent(node, itemId)
    } else {
      LinkView({ text: node.kind === 'cell' ? ' ' : node.source, parts: this.parts(node), cancelled: checked,
        textSize: node.kind === 'cell' ? 14 : itemId ? UiSize.listItemFont : UiSize.paragraphFont,
        lineHeight: node.kind === 'cell' ? undefined : itemId ? UiSize.listItemLineHeight : UiSize.paragraphLineHeight,
        revision: this.revision, editable: !this.readonly && !this.disabled, internalLinkProcessor: this.processor,
        editor: this.linkEditor, editingChanged: this.linkEditingChanged,
        activate: !this.readonly && (!this.disabled || (this.activateParagraph && node.id === this.nodes[0]?.id)) ?
          (): void => { this.activate(node) } : undefined,
        change: (link: CoreTextLink, value: CoreLinkValue | null): Promise<void> => this.changeLink(node, link, value) }).width('100%')
    }
  }

  private tableColumns(node: CoreContentNode): number {
    return (node.children ?? []).reduce((count: number, row: CoreContentNode): number =>
      Math.max(count, row.kind === 'row' ? (row.children?.length ?? 0) : 0), 0)
  }

  @Builder
  table(node: CoreContentNode) {
    if (this.tableColumns(node) > 3) {
      Scroll() { this.tableGrid(node, 92 * this.tableColumns(node)) }.width('100%')
        .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).edgeEffect(EdgeEffect.None)
    } else {
      this.tableGrid(node, '100%')
    }
  }

  @Builder
  tableGrid(node: CoreContentNode, width: number | string) {
    Column() {
      ForEach(node.children ?? [], (row: CoreContentNode) => {
        if (row.kind === 'rule') {
          Divider().color(UiColor.secondary)
        } else if (row.kind === 'row') {
          Row() {
            ForEach(row.children ?? [], (cell: CoreContentNode) => {
              Column() { this.inline(cell, false) }.layoutWeight(1).padding({ left: 8, right: 8, top: 5, bottom: 5 })
                .border({ width: { right: 0.5 }, color: UiColor.divider })
            }, (cell: CoreContentNode, index: number): string => `${index}:${cell.id}:${cell.source}`)
          }.width('100%').alignItems(VerticalAlign.Top).border({ width: { bottom: 0.5 }, color: UiColor.divider })
        }
      }, (row: CoreContentNode, index: number): string => `${index}:${row.id}:${row.source}`)
    }.width(width).alignItems(HorizontalAlign.Start).border({ width: 0.5, color: UiColor.divider })
  }

  @Builder
  item(node: CoreContentNode) {
    Row({ space: UiSize.listMarkerGap }) {
      if (node.checkbox) {
        Button(node.checkbox === 'checked' ? '✓' : node.checkbox === 'partial' ? '−' : '○')
          .width(UiSize.listMarkerWidth).height(44).padding(0).fontSize(19).fontColor(UiColor.secondary).backgroundColor(Color.Transparent)
          .enabled(!this.readonly && !this.disabled)
          .onClick((): void => { this.toggle({ type: 'setChecked', id: node.id, checked: node.checkbox !== 'checked' }) })
      } else {
        Text(node.marker ?? '•').width(UiSize.listMarkerWidth).padding({ top: 4 }).fontSize(UiSize.listItemFont).lineHeight(UiSize.listItemLineHeight).fontColor(UiColor.secondary)
      }
      Column() {
        this.blocks((): CoreContentNode[] => node.children ?? [], node.checkbox === 'checked', node.id)
        if (this.editNode?.id === node.id) { this.editorContent(node, node.id) }
      }.layoutWeight(1).padding({ top: node.checkbox ? 11 : 4 }).alignItems(HorizontalAlign.Start)
    }.width('100%').alignItems(VerticalAlign.Top)
  }

  @Builder
  appendTo(node: CoreContentNode, label: string) {
    if (this.editNode?.id === node.id && this.addingParagraph) {
      this.editorContent(this.editNode, '')
    } else if (!this.readonly && !this.disabled) {
      Text(label).fontSize(13).fontColor(UiColor.primary).height(36).width('100%')
        .onClick((): void => { this.startEdit({ id: node.id, kind: node.kind, source: '', blankLinesBefore: 0 }, true) })
    }
  }

  @Builder
  blocks(nodes: () => CoreContentNode[], checked: boolean = false, itemId: string = '') {
    ForEach(nodes(), (node: CoreContentNode, index: number) => {
      Column() {
        if (node.kind === 'paragraph') {
          this.inline(node, index === 0 && checked, itemId)
        } else if (node.kind === 'list') {
          ForEach(node.children ?? [], (item: CoreContentNode) => { this.item(item) },
            (item: CoreContentNode): string => item.id)
          this.appendTo(node, localizedText($r('app.string.text_add_entry_2')))
        } else if (node.kind === 'table') {
          this.table(node)
        } else if (node.kind === 'quote') {
          Column() {
            this.blocks((): CoreContentNode[] => node.children ?? [])
            this.appendTo(node, localizedText($r('app.string.text_add_paragraph')))
          }.padding({ left: 8 })
            .border({ width: { left: 1 }, color: UiColor.secondary }).width('100%')
        } else if (node.kind === 'literal') {
          Text(node.source).fontFamily('monospace').fontSize(13).fontColor(UiColor.text).width('100%')
        }
      }.width('100%').alignItems(HorizontalAlign.Start).margin({ top: index > 0 ? (node.blankLinesBefore > 0 ? 10 : 4) : 0 })
    }, (node: CoreContentNode, index: number): string => `${index}:${node.id}:${node.source}`)
  }

  build() {
    Column() {
      // 在 ForEach 刷新时读取订阅送达的节点，避免 Builder 保存初次渲染的数组。
      this.blocks((): CoreContentNode[] => this.nodes, this.completed, this.itemId)
      if (this.itemId && this.editNode?.id === this.itemId) { this.editorContent(this.editNode, this.itemId) }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
