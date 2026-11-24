import { InternalLinkProcessor } from '../../ui/InternalLinkProcessor'
import { CoreContentBlockChange, CoreContentNode, CoreContentBlock, CoreTask, CoreTaskChecklistChange, CoreTaskChecklistItem, CoreTaskModification, CoreTextLink, CoreLinkValue, CoreBridgeError, coreErrorMessage } from '../../services/NativeCoreService'
import { DataSetWriteError } from '../../services/DataSet'
import { TaskInlineSession } from '../../services/TaskInlineService'
import { TaskContentEditor } from './TaskContentEditor'
import { ChecklistFocusFrame, TaskChecklistBlock } from './TaskChecklistBlock'
import { TaskBlockController } from '../../ui/TaskBlockController'
import { checklistBlockEnd } from '../../ui/TaskChecklistReorder'
import { TaskInlineFocus } from '../../ui/TaskInlineFocus'
import { LinkEditController } from '../LinkView'
import { UiColor } from '../../ui/Theme'
import { KeyboardAvoidMode } from '@kit.ArkUI'
import { showDangerousConfirmation } from '../controls/DangerousConfirmation'

// 项目文档的编辑会话适配；正文直接复用区块控件，任务状态和标题由 TaskEditor 负责。
@Component
export struct TaskDocumentContent {
  modify: (task: CoreTask, changes: CoreTaskModification[]) => Promise<CoreTask> = async (): Promise<CoreTask> => { throw new Error('未提供正文数据管理接口') }
  readTask: (() => CoreTask | undefined) | undefined = undefined
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop @Watch('snapshotChanged') task: CoreTask | null = null
  @Prop blocks: CoreContentBlock[] = []
  @Prop contentTree: CoreContentNode[] | undefined = undefined
  @Prop contentRevision: string = ''
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
  @State addingAfter: string = ''
  @State newText: string = ''
  @State blockEditing: boolean = false
  @State linkEditing: boolean = false
  private blockEditor: TaskBlockController = new TaskBlockController()
  private linkEditor: LinkEditController = new LinkEditController()
  private active: boolean = false
  private coordinating: boolean = false
  private owner: string = ''
  private pending: Promise<boolean> | undefined = undefined
  private checkFocus: TaskInlineFocus = new TaskInlineFocus(
    (callback: () => void) => { this.getUIContext().postFrameCallback(new ChecklistFocusFrame(callback)) },
    (id: string) => { this.getUIContext().getFocusController().requestFocus(id) })

  aboutToAppear() { this.active = true; this.owner = `document-content:${this.task?.id ?? this.getUniqueId()}` }
  aboutToDisappear() { this.active = false; this.checkFocus.cancel(); TaskInlineSession.release(this.owner) }

  snapshotChanged() {
    if ((this.blockEditing || this.linkEditing || this.editingId || this.addingAfter || this.newText.trim()) &&
      this.task?.fileVersion !== this.current?.fileVersion) {
      this.blocked = true; this.message = '文件已变化，草稿已保留。'
    } else { this.current = undefined; this.blocked = false }
  }

  content(): CoreContentBlock[] { return this.current?.editContent.blocks ?? this.blocks }
  isReadonly(): boolean { return this.readonly || this.task === null }

  async session(): Promise<boolean> {
    if (this.isReadonly() || this.blocked || this.working) return false
    if (!await TaskInlineSession.begin(this.owner, async (): Promise<boolean> => this.finish())) return false
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE)
    // 会话开始取得来源的最新上下文；进入编辑后冻结源版本，保存时不静默改用新版本。
    if (!this.current) this.current = this.readTask ? this.readTask() : this.task ?? undefined
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

  async commit(changes: CoreTaskModification[], sourceVersion?: string): Promise<boolean> {
    if (this.isReadonly() || this.blocked || !this.current || this.working) return false
    const task = this.current
    if (sourceVersion !== undefined && task.fileVersion !== sourceVersion) {
      this.message = '文件已变化，请重新选择移动位置'
      return false
    }
    this.working = true; this.message = ''
    let committed: boolean = false
    try {
      const current = await this.modify(task, changes)
      committed = true
      if (this.active) { this.current = current; this.blocked = false; this.message = '' }
      return true
    } catch (error) {
      committed = committed || (error as DataSetWriteError).committed === true
      if (this.active) {
        const message = coreErrorMessage(error as CoreBridgeError)
        this.blocked = committed || message.includes('版本')
        this.message = committed ? `修改已保存，重新读取失败。 ${message}` : message
      }
      return false
    } finally { this.working = false; this.releaseIdle() }
  }

  async saveBlock(block: CoreContentBlock, source: string): Promise<boolean> {
    return this.commit([{ field: 'CONTENT_BLOCK', value: { type: 'replace', id: block.id, source } }])
  }

  reloadBlockDraft(): void {
    showDangerousConfirmation(this.getUIContext(), {
      title: '重新载入正文？', message: '将放弃未保存的输入，读取文件中的最新内容。', confirmLabel: '重新载入',
      onConfirm: (): void => {
        if (!this.active || this.working) return
        const latest = this.readTask?.() ?? this.task ?? undefined
        if (!latest) return
        this.blockEditor.cancel()
        this.checkFocus.cancel()
        this.current = latest
        this.blocked = false
        this.message = ''
        this.releaseIdle()
      }
    })
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
      // 混排列表的 checkbox 来自正文树，保留同版本的源定位。
      if (change.type !== 'add' && !current && before.fileVersion !== this.current?.fileVersion) return
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
      if (!current) return
      this.adding = false; this.addingAfter = ''
      this.editingId = current.id; this.editingText = current.text
      this.checkFocus.request(`inline_check_${current.id}`)
    } finally { this.coordinating = false; this.releaseIdle() }
  }

  async addCheck(after: string = '') {
    if (!await this.session()) return
    this.coordinating = true
    try {
      if (!await this.blockEditor.finish() || !await this.linkEditor.finish() || !await this.saveCheck(false) || !this.active) return
      this.addingAfter = after; this.adding = true
      this.checkFocus.request(`inline_new_check_${this.owner}`)
    } finally { this.coordinating = false; this.releaseIdle() }
  }

  async saveCheck(next: boolean): Promise<boolean> {
    if (this.pending) return this.pending
    if (!this.editingId && !this.newText.trim()) return true
    if (this.isReadonly() || this.blocked || this.working || !this.current) return false
    this.pending = this.commitCheck(this.current, next)
    try { return await this.pending }
    finally { this.pending = undefined; this.releaseIdle() }
  }

  private async commitCheck(task: CoreTask, next: boolean): Promise<boolean> {
    const id = this.editingId
    const text = id ? this.editingText : this.newText
    const items = task.editContent.checklist
    const anchor = id || this.addingAfter
    const index = items.findIndex(item => item.id === anchor)
    if (anchor && index < 0) { this.message = '清单条目已变化，请刷新'; return false }
    const change: CoreTaskChecklistChange = id ? { type: 'edit', id, text } :
      anchor ? { type: 'insertAfter', id: anchor, text } : { type: 'add', text }
    if ((!id || items[index].text !== text) && !await this.commit([{ field: 'CHECKLIST', value: change }])) return false
    const nextIndex = !id && anchor ? checklistBlockEnd(items, index) : index
    this.adding = next && this.active
    this.addingAfter = this.adding ? this.current?.editContent.checklist[nextIndex]?.id ?? '' : ''
    this.editingText = ''; this.newText = ''; this.editingId = ''
    if (this.adding) this.checkFocus.request(`inline_new_check_${this.owner}`)
    return true
  }

  releaseIdle() {
    if (!this.coordinating && !this.working && !this.blockEditing && !this.linkEditing && !this.editingId && !this.adding && !this.newText.trim()) {
      TaskInlineSession.release(this.owner)
    }
  }

  async finish(): Promise<boolean> {
    this.checkFocus.cancel()
    if (!await this.blockEditor.finish() || !await this.linkEditor.finish() || !await this.saveCheck(false) || this.blocked) return false
    this.checkFocus.cancel()
    this.adding = false; this.addingAfter = ''; TaskInlineSession.release(this.owner)
    return true
  }

  lastChecklist(block: CoreContentBlock): boolean {
    const blocks = this.content().filter((entry: CoreContentBlock): boolean => entry.kind === 'checklist')
    return blocks.length > 0 && blocks[blocks.length - 1].id === block.id
  }

  private tree(): CoreContentNode[] | undefined { return this.current?.editContent.contentTree ?? this.task?.editContent.contentTree ?? this.contentTree }

  async writeContentNode(change: CoreContentBlockChange): Promise<void> {
    if (!await this.commit([{ field: 'CONTENT_BLOCK', value: change }])) throw new Error(this.message || '修改正文失败，请重试')
  }

  @Builder
  checklist(index: () => number) {
    TaskChecklistBlock({ items: this.content()[index()].items, readonly: this.isReadonly(), disabled: this.working || this.blocked,
      tree: this.tree()?.find(node => node.id === this.content()[index()].id), revision: this.current?.fileVersion ?? this.task?.fileVersion ?? '',
      processor: this.internalLinkProcessor, editor: this.blockEditor, linkEditor: this.linkEditor,
      beginNode: (): Promise<boolean> => this.beginBlock(this.content()[index()]), writeNode: change => this.writeContentNode(change),
      editingChanged: (editing: boolean): void => { this.blockEditing = editing; if (!editing) this.releaseIdle() },
      linkEditingChanged: (editing: boolean): void => { this.linkEditing = editing; if (editing) this.session(); else this.releaseIdle() },
      indentStep: this.projectReading ? 8 : 12,
      ownerKey: this.owner, blockId: this.content()[index()].id, editingId: this.editingId, editingText: this.editingText,
      adding: this.adding && (this.addingAfter ? this.content()[index()].items.some(item => item.id === this.addingAfter) :
        this.lastChecklist(this.content()[index()])), addingAfter: this.addingAfter,
      newText: this.newText, showAdd: this.lastChecklist(this.content()[index()]),
      toggle: (change: CoreTaskChecklistChange): void => { this.changeCheck(change) },
      edit: (item: CoreTaskChecklistItem): void => { this.editCheck(item) },
      editChanged: (text: string): void => { this.editingText = text },
      newChanged: (text: string): void => { this.newText = text },
      save: (next: boolean, id: string): void => {
        if (id ? id === this.editingId : this.adding) this.saveCheck(next)
      },
      remove: (item: CoreTaskChecklistItem): void => { this.changeCheck({ type: 'remove', id: item.id }) },
      add: (): void => { this.addCheck() },
      inputAppeared: (id: string): void => { this.checkFocus.appeared(id) },
      inputDisappeared: (id: string): void => { this.checkFocus.disappeared(id) },
      inputVisible: (id: string): void => { this.checkFocus.visible(id) } }).width('100%')
  }

  build() {
    Column({ space: 8 }) {
      TaskContentEditor({ internalLinkProcessor: this.internalLinkProcessor, blocks: this.content(), contentTree: this.tree(), writeNode: change => this.writeContentNode(change),
        toggle: change => { this.changeCheck(change) }, beginEmpty: (): Promise<boolean> => this.session(), readonly: this.isReadonly(), disabled: this.working || this.blocked,
        projectReading: this.projectReading, checklistEditing: this.editingId !== '' || this.adding,
        revision: this.current?.fileVersion ?? this.task?.fileVersion ?? this.contentRevision, contentBackground: this.contentBackground,
        moveVersion: this.current?.fileVersion ?? this.task?.fileVersion ?? '',
        moveContent: (id: string, beforeId: string | null, version: string): Promise<boolean> =>
          this.commit([{ field: 'CONTENT_BLOCK', value: { type: 'move', id, beforeId } }], version),
        ownerKey: this.owner, editor: this.blockEditor, linkEditor: this.linkEditor,
        checklist: (index: () => number): void => { this.checklist(index) },
        begin: (block: CoreContentBlock): Promise<boolean> => this.beginBlock(block),
        save: (block: CoreContentBlock, source: string): Promise<boolean> => this.saveBlock(block, source),
        changeLink: (block: CoreContentBlock, link: CoreTextLink, value: CoreLinkValue | null): Promise<void> => this.changeBlockLink(block, link, value),
        editingChanged: (editing: boolean): void => { this.blockEditing = editing; if (!editing) this.releaseIdle() },
        linkEditingChanged: (editing: boolean): void => { this.linkEditing = editing; if (editing) this.session(); else this.releaseIdle() } }).width('100%')
      if (this.message) { Text(this.message).fontSize(12).fontColor(UiColor.error).width('100%') }
      if (this.blocked && this.blockEditing) {
        Button('重新载入').height(36).fontColor(UiColor.primary).backgroundColor(Color.Transparent)
          .enabled(!this.working).onClick((): void => { this.reloadBlockDraft() })
      }
    }.width('100%')
  }
}
