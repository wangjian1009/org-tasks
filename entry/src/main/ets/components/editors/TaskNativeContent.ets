import { util } from '@kit.ArkTS'
import { CoreContentBlockChange, CoreContentNode, CoreContentInline, CoreTaskChecklistChange, CoreTitlePart,
  CoreTextLink, CoreLinkValue } from '../../services/NativeCoreService'
import { InternalLinkProcessor } from '../../ui/InternalLinkProcessor'
import { LinkEditController, LinkView } from '../LinkView'
import { TaskBlockController } from '../../ui/TaskBlockController'
import { UiColor } from '../../ui/Theme'

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
  @State insertion: CoreTextLink | undefined = undefined
  @State inserting: boolean = false
  @State saving: boolean = false
  @State error: string = ''
  private editKey: string = ''
  private editVersion: string = ''
  private selectionStart: number = 0
  private selectionEnd: number = 0
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
    this.selectionStart = this.draft.length
    this.selectionEnd = this.draft.length
    this.editVersion = version
    this.error = ''
    this.addingParagraph = append
    this.editNode = node
    this.editingChanged(true)
  }

  private cancel(): void {
    this.editNode = undefined
    this.insertion = undefined
    this.inserting = false
    this.editor.release(this.editKey)
    this.editingChanged(false)
  }

  private async finish(): Promise<boolean> {
    if (this.pending) return this.pending
    const node = this.editNode
    if (!node) return true
    if (this.saving || this.inserting) return false
    if (this.editVersion !== this.revision) {
      this.error = '内容已变化，请把草稿拷贝后重新载入'
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
      this.error = (error as Error).message || '保存失败，请重试'
      return false
    }
  }

  private containerId(node: CoreContentNode): string { return this.addingParagraph && node.kind === 'list' ? `list:${node.id}` : node.id }

  private startInsert(node: CoreContentNode): void {
    const start = this.selectionStart
    const end = this.selectionEnd
    const encoder = new util.TextEncoder()
    this.insertion = {
      start: encoder.encodeInto(node.source.slice(0, start))?.length ?? 0,
      end: encoder.encodeInto(node.source.slice(0, end))?.length ?? 0,
      source: '', title: node.source.slice(start, end), url: ''
    }
  }

  private async insertLink(node: CoreContentNode, link: CoreTextLink, value: CoreLinkValue | null): Promise<void> {
    if (!value || this.editVersion !== this.revision) throw new Error('内容已变化，请重新载入后编辑')
    await this.write(this.addingParagraph ? { type: 'insertLinkedParagraph', id: this.containerId(node), value } :
      { type: 'insertLink', id: node.id, start: link.start, end: link.end, source: node.source, value })
    this.cancel()
  }

  private async changeLink(node: CoreContentNode, link: CoreTextLink, value: CoreLinkValue | null): Promise<void> {
    const version = this.revision
    if (!await this.begin() || version !== this.revision) throw new Error('内容已变化，请重新载入后编辑')
    await this.write({ type: 'treeLink', id: node.id, link, value })
  }

  private activate(node: CoreContentNode): void {
    if (node.kind === 'paragraph' && this.nodes[0]?.id === node.id && this.activateParagraph) {
      this.activateParagraph(node)
    } else {
      this.startEdit(node)
    }
  }

  @Builder
  editorContent(node: CoreContentNode, itemId: string) {
    Column({ space: 4 }) {
      TextArea({ text: this.draft, placeholder: node.kind === 'cell' ? '单元格' : '段落' }).id(this.editKey).defaultFocus(true)
        .width('100%').height('auto').fontSize(14).fontColor(UiColor.text).minLines(1)
        .backgroundColor(UiColor.field).enabled(!this.saving && !this.inserting)
        .onChange((value: string): void => { this.draft = value })
        .onBlur((): void => { if (!this.insertion && !this.inserting) this.finish() })
        .enterKeyType(EnterKeyType.NEW_LINE)
        .onTextSelectionChange((start: number, end: number): void => {
          this.selectionStart = start
          this.selectionEnd = end
        })
      LinkView({ textSize: 14, editor: this.linkEditor, revision: this.revision, editable: true, insertion: this.insertion,
          change: (link: CoreTextLink, value: CoreLinkValue | null): Promise<void> => this.insertLink(node, link, value),
          editingChanged: (editing: boolean): void => {
            this.inserting = editing
            if (!editing) this.insertion = undefined
          } }).width('100%')
      Row({ space: 8 }) {
        Button('链接').height(36).fontSize(13).fontColor(UiColor.primary).backgroundColor(Color.Transparent).focusable(false)
          .enabled(!this.saving && !this.inserting && this.draft === node.source)
          .onClick((): void => { this.startInsert(node) })
        if (!this.addingParagraph && itemId) {
            Button('添加说明').height(36).fontSize(13).fontColor(UiColor.primary).backgroundColor(Color.Transparent).focusable(false)
              .enabled(!this.saving && !this.inserting && this.draft === node.source)
              .onClick((): void => {
                this.cancel()
                this.startEdit({ id: itemId, kind: 'item', source: '', blankLinesBefore: 0 }, true)
              })
        }
      }.width('100%').justifyContent(FlexAlign.End)
      if (this.error) { Text(this.error).fontSize(12).fontColor(UiColor.error) }
    }.width('100%').alignItems(HorizontalAlign.Start)
      .onClick((): void => { LinkEditController.protectInteraction() })
  }

  @Builder
  inline(node: CoreContentNode, checked: boolean, itemId: string = '') {
    if (this.editNode?.id === node.id) {
      this.editorContent(node, itemId)
    } else {
      LinkView({ text: node.kind === 'cell' ? ' ' : node.source, parts: this.parts(node), textSize: 14, cancelled: checked,
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
    Row({ space: 4 }) {
      if (node.checkbox) {
        Button(node.checkbox === 'checked' ? '✓' : node.checkbox === 'partial' ? '−' : '○')
          .width(28).height(44).padding(0).fontSize(19).fontColor(UiColor.secondary).backgroundColor(Color.Transparent)
          .enabled(!this.readonly && !this.disabled)
          .onClick((): void => { this.toggle({ type: 'setChecked', id: node.id, checked: node.checkbox !== 'checked' }) })
      } else {
        Text(node.marker ?? '•').width(28).padding({ top: 4 }).fontSize(14).fontColor(UiColor.secondary)
      }
      Column() {
        this.blocks(node.children ?? [], node.checkbox === 'checked', node.id)
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
  blocks(nodes: CoreContentNode[], checked: boolean = false, itemId: string = '') {
    ForEach(nodes, (node: CoreContentNode, index: number) => {
      Column() {
        if (node.kind === 'paragraph') {
          this.inline(node, index === 0 && checked, itemId)
        } else if (node.kind === 'list') {
          ForEach(node.children ?? [], (item: CoreContentNode) => { this.item(item) },
            (item: CoreContentNode): string => item.id)
          this.appendTo(node, '添加条目')
        } else if (node.kind === 'table') {
          this.table(node)
        } else if (node.kind === 'quote') {
          Column() {
            this.blocks(node.children ?? [])
            this.appendTo(node, '添加段落')
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
      this.blocks(this.nodes, this.completed, this.itemId)
      if (this.itemId && this.editNode?.id === this.itemId) { this.editorContent(this.editNode, this.itemId) }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
