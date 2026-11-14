import { InternalLinkProcessor } from '../../ui/InternalLinkProcessor'
import { CoreContentBlock, CoreTask, CoreTaskChecklistChange, CoreTaskChecklistItem, CoreTaskModification, CoreTextLink, CoreLinkValue, CoreBridgeError, coreErrorMessage } from '../../services/NativeCoreService'
import { TaskInlineService, TaskInlineSession } from '../../services/TaskInlineService'
import { TaskContentBlocks } from './TaskContentBlocks'
import { TaskChecklistBlock } from './TaskChecklistBlock'
import { TaskBlockController } from '../../ui/TaskBlockController'
import { LinkEditController } from '../LinkView'
import { UiColor } from '../../ui/Theme'
import { KeyboardAvoidMode } from '@kit.ArkUI'

// 项目文档的编辑会话适配；正文直接复用区块控件，任务状态和标题由 TaskEditor 负责。
@Component
export struct TaskDocumentContent {
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop @Watch('snapshotChanged') task: CoreTask | null = null
  @Prop blocks: CoreContentBlock[] = []
  @Prop readonly: boolean = false
  @Prop projectReading: boolean = false
  @Prop contentBackground: string = UiColor.surface
  @State current: CoreTask | undefined = undefined
  @State working: boolean = false
  @State blocked: boolean = false
  @State message: string = ''
  @State editingId: string = ''
  @State editingText: string = ''
  @State adding: boolean = false
  @State newText: string = ''
  @State blockEditing: boolean = false
  @State linkEditing: boolean = false
  private blockEditor: TaskBlockController = new TaskBlockController()
  private linkEditor: LinkEditController = new LinkEditController()
  private active: boolean = false
  private coordinating: boolean = false
  private owner: string = ''
  private pending: Promise<boolean> | undefined = undefined

  aboutToAppear() { this.active = true; this.owner = `document-content:${this.task?.id ?? this.getUniqueId()}` }
  aboutToDisappear() { this.active = false; TaskInlineSession.release(this.owner) }

  snapshotChanged() {
    if ((this.blockEditing || this.linkEditing || this.editingId || this.newText.trim()) && this.task?.fileVersion !== this.current?.fileVersion) {
      this.blocked = true; this.message = '文件已变化，草稿已保留，请取消编辑后刷新'
    } else { this.current = undefined; this.blocked = false }
  }

  content(): CoreContentBlock[] { return this.current?.editContent.blocks ?? this.blocks }
  isReadonly(): boolean { return this.readonly || this.task === null }

  async session(): Promise<boolean> {
    if (this.isReadonly() || this.blocked || this.working) return false
    if (!await TaskInlineSession.begin(this.owner, async (): Promise<boolean> => this.finish())) return false
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE)
    if (!this.current && this.task) this.current = this.task
    return this.current !== undefined
  }

  async beginBlock(block: CoreContentBlock): Promise<boolean> {
    if (!await this.session()) return false
    const version = this.current?.fileVersion
    this.coordinating = true
    try { if (!await this.saveCheck(false) || version !== this.current?.fileVersion) return false }
    finally { this.coordinating = false }
    return this.content().some((current: CoreContentBlock): boolean => current.id === block.id && current.source === block.source)
  }

  async commit(changes: CoreTaskModification[]): Promise<boolean> {
    if (this.isReadonly() || this.blocked || !this.current || this.working) return false
    const task = this.current
    this.working = true; this.message = ''
    let committed: boolean = false
    try {
      await TaskInlineService.modify(this.getUIContext().getHostContext()!, task, changes, true)
      committed = true
      const current = await TaskInlineService.reload(this.getUIContext().getHostContext()!, task, true)
      if (this.active) this.current = current
      return true
    } catch (error) {
      if (this.active) {
        this.blocked = committed
        this.message = `${committed ? '修改已保存，重新读取失败，请刷新：' : ''}${coreErrorMessage(error as CoreBridgeError)}`
      }
      return false
    } finally { this.working = false }
  }

  async saveBlock(block: CoreContentBlock, source: string): Promise<boolean> {
    return this.commit([{ field: 'CONTENT_BLOCK', value: { type: 'replace', id: block.id, source } }])
  }

  async changeBlockLink(block: CoreContentBlock, link: CoreTextLink, value: CoreLinkValue | null): Promise<void> {
    if (!await this.session() || !await this.commit([{ field: 'CONTENT_BLOCK', value: { type: 'link', id: block.id, link, value } }])) {
      throw new Error(this.message || '链接修改失败，请重试')
    }
  }

  async changeCheck(change: CoreTaskChecklistChange) {
    if (!await this.session()) return
    this.coordinating = true
    try {
      const before = this.current!
      if (!await this.blockEditor.finish() || !await this.linkEditor.finish() || before.fileVersion !== this.current?.fileVersion) return
      const id = change.type === 'add' ? '' : change.id
      const index = before.editContent.checklist.findIndex((item: CoreTaskChecklistItem): boolean => item.id === id)
      if (!await this.saveCheck(false) || !this.active) return
      const current = this.current?.editContent.checklist[index]
      if (change.type !== 'add' && !current) return
      if (change.type === 'setChecked' && current) change = { type: 'setChecked', id: current.id, checked: change.checked }
      if (change.type === 'remove' && current) change = { type: 'remove', id: current.id }
      await this.commit([{ field: 'CHECKLIST', value: change }])
    } finally { this.coordinating = false; this.releaseIdle() }
  }

  async editCheck(item: CoreTaskChecklistItem) {
    if (!await this.session()) return
    this.coordinating = true
    try {
      const before = this.current!
      if (!await this.blockEditor.finish() || !await this.linkEditor.finish() || before.fileVersion !== this.current?.fileVersion) return
      const index = before.editContent.checklist.findIndex((current: CoreTaskChecklistItem): boolean => current.id === item.id)
      if (!await this.saveCheck(false) || !this.active) return
      const current = this.current?.editContent.checklist[index]
      if (current) { this.editingId = current.id; this.editingText = current.text }
    } finally { this.coordinating = false; this.releaseIdle() }
  }

  async addCheck() {
    if (!await this.session()) return
    this.coordinating = true
    try {
      if (!await this.blockEditor.finish() || !await this.linkEditor.finish() || !await this.saveCheck(false) || !this.active) return
      this.adding = true
    } finally { this.coordinating = false; this.releaseIdle() }
  }

  async saveCheck(next: boolean): Promise<boolean> {
    if (this.pending) return this.pending
    if (!this.editingId && !this.newText.trim()) return true
    if (this.isReadonly() || this.blocked || this.working) return false
    const change: CoreTaskChecklistChange = this.editingId ? { type: 'edit', id: this.editingId, text: this.editingText } : { type: 'add', text: this.newText }
    this.pending = this.commit([{ field: 'CHECKLIST', value: change }])
    try {
      if (!await this.pending) return false
      this.editingId = ''; this.editingText = ''; this.newText = ''; this.adding = next
      this.releaseIdle()
      return true
    } finally { this.pending = undefined }
  }

  releaseIdle() {
    if (!this.coordinating && !this.working && !this.blockEditing && !this.linkEditing && !this.editingId && !this.adding && !this.newText.trim()) {
      TaskInlineSession.release(this.owner)
    }
  }

  async finish(): Promise<boolean> {
    if (!await this.blockEditor.finish() || !await this.linkEditor.finish() || !await this.saveCheck(false) || this.blocked) return false
    this.adding = false; TaskInlineSession.release(this.owner)
    return true
  }

  lastChecklist(block: CoreContentBlock): boolean {
    const blocks = this.content().filter((entry: CoreContentBlock): boolean => entry.kind === 'checklist')
    return blocks.length > 0 && blocks[blocks.length - 1].id === block.id
  }

  @Builder
  checklist(block: CoreContentBlock) {
    TaskChecklistBlock({ items: block.items, readonly: this.isReadonly(), disabled: this.working || this.blocked,
      ownerKey: this.owner, blockId: block.id, editingId: this.editingId, editingText: this.editingText,
      adding: this.adding && this.lastChecklist(block), newText: this.newText, showAdd: this.lastChecklist(block),
      toggle: (change: CoreTaskChecklistChange): void => { this.changeCheck(change) },
      edit: (item: CoreTaskChecklistItem): void => { this.editCheck(item) },
      editChanged: (text: string): void => { this.editingText = text },
      newChanged: (text: string): void => { this.newText = text },
      save: (next: boolean): void => { this.saveCheck(next) },
      remove: (item: CoreTaskChecklistItem): void => { this.changeCheck({ type: 'remove', id: item.id }) },
      add: (): void => { this.addCheck() },
      inputAppeared: (id: string): void => {
        setTimeout((): void => { if (this.active) this.getUIContext().getFocusController().requestFocus(id) }, 0)
      } }).width('100%')
  }

  build() {
    Column({ space: 8 }) {
      TaskContentBlocks({ internalLinkProcessor: this.internalLinkProcessor, blocks: this.content(), readonly: this.isReadonly(), disabled: this.working || this.blocked,
        projectReading: this.projectReading,
        revision: this.current?.fileVersion ?? this.task?.fileVersion ?? '', contentBackground: this.contentBackground,
        ownerKey: this.owner, editor: this.blockEditor, linkEditor: this.linkEditor,
        checklist: (block: CoreContentBlock): void => { this.checklist(block) },
        begin: (block: CoreContentBlock): Promise<boolean> => this.beginBlock(block),
        save: (block: CoreContentBlock, source: string): Promise<boolean> => this.saveBlock(block, source),
        changeLink: (block: CoreContentBlock, link: CoreTextLink, value: CoreLinkValue | null): Promise<void> => this.changeBlockLink(block, link, value),
        editingChanged: (editing: boolean): void => { this.blockEditing = editing; if (!editing) this.releaseIdle() },
        linkEditingChanged: (editing: boolean): void => { this.linkEditing = editing; if (editing) this.session(); else this.releaseIdle() } }).width('100%')
      if (this.message) { Text(this.message).fontSize(12).fontColor(UiColor.error).width('100%') }
    }.width('100%')
  }
}
