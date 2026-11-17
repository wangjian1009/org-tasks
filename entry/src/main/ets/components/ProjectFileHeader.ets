import { LengthMetrics, window } from '@kit.ArkUI'
import { CoreFileHeaderEntry, CoreFileHeaderValueChange } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'
import { DataSetWriteError } from '../services/DataSet'
import { PageNavigator } from '../services/PageNavigator'
import { TaskInlineSession } from '../services/TaskInlineService'
import { LinkEditController } from './LinkView'

interface HeaderDraft {
  entry: CoreFileHeaderEntry
  text: string
  tags: string[]
  newTag: string
}

export class ProjectHeaderNavigation {
  close: () => boolean = () => false
}

// 整个属性区域长按进入原位编辑，所有草稿使用同一文件版本并一起保存。
@Component
export struct ProjectFileHeader {
  @Prop headerEntries: CoreFileHeaderEntry[] = []
  @Prop tags: string[] = []
  @Prop selectedTags: string[] = []
  @Prop fileVersion: string = ''
  @Prop categoryOptions: string[] = []
  @Prop category: string = ''
  @Prop selectedCategory: string = ''
  beforeEdit: () => Promise<boolean> = async () => true
  save: (changes: CoreFileHeaderValueChange[], version: string) => Promise<void> = async () => {}
  navigation: ProjectHeaderNavigation = new ProjectHeaderNavigation()
  toggle: (tag: string) => void = () => {}
  toggleCategory: () => void = () => {}
  @State editing: boolean = false
  @State editEntries: CoreFileHeaderEntry[] = []
  @State drafts: HeaderDraft[] = []
  @State creatingTagId: string = ''
  @State busy: boolean = false
  @State saved: boolean = false
  @State message: string = ''
  private sourceVersion: string = ''
  private suppressClickUntil: number = 0
  private alive: boolean = false
  private opening: boolean = false
  private ownerKey: string = ''
  private typing: boolean = false
  private hostWindow: window.Window | undefined = undefined
  private keyboardChanged = (height: number): void => { if (this.alive) this.typing = height > 0 }
  private stopExternalGuard: (() => void) | undefined = undefined

  async aboutToAppear(): Promise<void> {
    this.alive = true; this.ownerKey = `project-header:${this.getUniqueId()}`
    this.stopExternalGuard = PageNavigator.shared.watchExternalLeaveGuard((): boolean => !this.editing)
    this.navigation.close = (): boolean => {
      if (!this.editing) return false
      if (this.typing) { this.getUIContext().getFocusController().clearFocus(); this.typing = false }
      else this.closeEditor()
      return true
    }
    try {
      const current = await window.getLastWindow(this.getUIContext().getHostContext()!)
      if (!this.alive) return
      this.hostWindow = current; current.on('keyboardHeightChange', this.keyboardChanged)
    } catch (_) {}
  }

  aboutToDisappear(): void {
    this.alive = false; this.stopExternalGuard?.(); this.stopExternalGuard = undefined
    TaskInlineSession.release(this.ownerKey); this.navigation.close = (): boolean => false
    try { this.hostWindow?.off('keyboardHeightChange', this.keyboardChanged) } catch (_) {}
  }

  toast(message: string): void {
    try { this.getUIContext().getPromptAction().showToast({ message }) } catch (_) {}
  }

  async openEditor(): Promise<void> {
    if (this.editing || this.opening || this.busy) return
    this.suppressClickUntil = Date.now() + 1000; this.opening = true
    try {
      if (!await this.beforeEdit() || !this.alive) return
      if (!this.fileVersion || !this.headerEntries.some(entry => !!entry.edit)) return
      this.sourceVersion = this.fileVersion
      this.editEntries = [...this.headerEntries]
      this.drafts = this.editEntries.filter(entry => !!entry.edit).map((entry: CoreFileHeaderEntry): HeaderDraft =>
        ({ entry, text: entry.value, tags: [...entry.tags], newTag: '' }))
      if (!await TaskInlineSession.begin(this.ownerKey, async (): Promise<boolean> => {
        if (this.busy || this.dirty()) { this.toast('请先保存或取消属性修改'); return false }
        this.finishEditor(); return true
      })) return
      if (!this.alive) { TaskInlineSession.release(this.ownerKey); return }
      this.message = ''; this.saved = false; this.creatingTagId = ''; this.editing = true
    } catch (error) { this.toast((error as Error).message) }
    finally { this.opening = false }
  }

  entries(): CoreFileHeaderEntry[] { return this.editing ? this.editEntries : this.headerEntries }
  draft(id: string): HeaderDraft { return this.drafts.find(item => item.entry.id === id)! }
  tagEditor(entry: CoreFileHeaderEntry): boolean { return entry.edit?.kind === 'fileTags' || entry.edit?.kind === 'tagConfig' }
  setText(id: string, text: string): void { this.drafts = this.drafts.map(item => item.entry.id === id ? { entry: item.entry, text, tags: item.tags, newTag: item.newTag } : item) }
  setNewTag(id: string, newTag: string): void { this.drafts = this.drafts.map(item => item.entry.id === id ? { entry: item.entry, text: item.text, tags: item.tags, newTag } : item) }
  setTags(id: string, tags: string[]): void { this.drafts = this.drafts.map(item => item.entry.id === id ? { entry: item.entry, text: item.text, tags, newTag: item.newTag } : item) }

  removeTag(id: string, tag: string): void {
    if (!this.editing || this.busy || this.saved) return
    const item = this.draft(id)
    if (item.entry.edit?.protectedTags.includes(tag)) return
    this.setTags(id, item.tags.filter(value => value !== tag))
  }

  startTag(id: string): void {
    if (!this.editing || this.busy || this.saved) return
    if (this.creatingTagId) this.addTag(this.creatingTagId)
    this.creatingTagId = id
  }

  focusNewTag(id: string, index: number): void {
    setTimeout((): void => {
      if (this.alive && this.editing && this.creatingTagId === id) {
        this.getUIContext().getFocusController().requestFocus(`project_header_tag_input_${index}`)
      }
    }, 0)
  }

  addTag(id: string): void {
    if (!this.editing || this.busy || this.saved) return
    const item = this.draft(id), name = item.newTag.trim()
    if (name && !item.tags.includes(name)) this.setTags(id, item.tags.concat(name))
    this.setNewTag(id, '')
    if (this.creatingTagId === id) this.creatingTagId = ''
  }

  changes(): CoreFileHeaderValueChange[] {
    const changes: CoreFileHeaderValueChange[] = []
    for (const item of this.drafts) {
      if (this.tagEditor(item.entry)) {
        const name = item.newTag.trim()
        const tags = name && !item.tags.includes(name) ? item.tags.concat(name) : item.tags
        if (JSON.stringify(tags) !== JSON.stringify(item.entry.tags)) changes.push({ entryId: item.entry.id, value: { type: 'tags', value: tags } })
      } else if (item.text !== item.entry.value) changes.push({ entryId: item.entry.id, value: { type: 'text', value: item.text } })
    }
    return changes
  }

  dirty(): boolean { return this.changes().length > 0 }
  finishEditor(): void {
    this.editing = false; this.typing = false; this.creatingTagId = ''; this.suppressClickUntil = Date.now() + 300
    TaskInlineSession.release(this.ownerKey)
  }

  closeEditor(): void {
    if (this.busy) return
    if (this.dirty() && !this.saved) {
      this.getUIContext().showAlertDialog({ title: '放弃属性修改？', message: '本次未保存的修改将被丢弃。',
        primaryButton: { value: '继续编辑', action: (): void => {} },
        secondaryButton: { value: '放弃修改', action: (): void => { this.finishEditor() } } })
    } else this.finishEditor()
  }

  async submitEditor(): Promise<void> {
    if (!this.editing || this.busy) return
    if (this.saved || !this.dirty()) { this.finishEditor(); return }
    if (this.sourceVersion !== this.fileVersion) { this.message = '文件已更新，输入已保留。请取消后重新进入编辑。'; return }
    this.busy = true; this.message = ''
    try {
      await this.save(this.changes(), this.sourceVersion)
      if (this.alive) { this.saved = true; this.finishEditor() }
    } catch (error) {
      if (this.alive) {
        this.saved = error instanceof DataSetWriteError && error.committed
        this.message = this.saved ? '已保存，但页面更新失败。请结束编辑后刷新查看。' : (error as Error).message
      }
    } finally { if (this.alive) this.busy = false }
  }

  allowFilterClick(): boolean { return !this.editing && !this.opening && Date.now() >= this.suppressClickUntil }
  label(entry: CoreFileHeaderEntry): string {
    const name = entry.name.toUpperCase()
    if (entry.keyword && name === 'TAGS') return 'tag'
    if (entry.keyword && name === 'FILETAGS') return 'filetag'
    return entry.name
  }
  tagsForEntry(entry: CoreFileHeaderEntry): string[] { return entry.tags.filter(tag => this.tags.includes(tag)) }

  @Builder
  tagChip(tag: string) {
    Button({ type: ButtonType.Normal }) {
      Text(this.selectedTags.includes(tag) ? `✓ ${tag}` : tag).fontSize(16).lineHeight(22)
        .fontColor(this.selectedTags.includes(tag) ? UiColor.onPrimary : UiColor.text)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 180 })
        .padding({ left: 6, right: 6, top: 3, bottom: 3 })
    }.width('auto').height(32).padding(0).borderRadius(4).flexShrink(0)
      .backgroundColor(this.selectedTags.includes(tag) ? UiColor.primary : Color.Transparent)
      .id(`project_filter_tag_${tag}`).onClick((): void => { if (this.allowFilterClick()) this.toggle(tag) })
      .accessibilityText(`${tag}，${this.selectedTags.includes(tag) ? '已选中，点击取消筛选' : '未选中，点击加入筛选'}`)
  }

  @Builder
  categoryValue(value: string) {
    Button({ type: ButtonType.Normal }) {
      Text(this.selectedCategory === value ? `✓ ${value}` : value).fontSize(16).lineHeight(22)
        .fontColor(this.selectedCategory === value ? UiColor.onPrimary : UiColor.text)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 180 })
        .padding({ left: 6, right: 6, top: 3, bottom: 3 })
    }.width('auto').height(32).padding(0).borderRadius(4)
      .backgroundColor(this.selectedCategory === value ? UiColor.primary : Color.Transparent)
      .id('project_filter_category').onClick((): void => { if (this.allowFilterClick()) this.toggleCategory() })
  }

  @Builder
  fileTag(tag: string) {
    Text(tag).fontSize(16).lineHeight(22).fontColor(UiColor.secondary)
      .padding({ left: 6, right: 6, top: 2, bottom: 2 }).backgroundColor(UiColor.field).borderRadius(4)
  }

  @Builder
  inlineTags(entry: CoreFileHeaderEntry, index: number) {
    Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(entry.edit!.kind === 'fileTags' ? 4 : 2), cross: LengthMetrics.vp(2) } }) {
      ForEach(this.draft(entry.id).tags, (tag: string) => {
        Button({ type: ButtonType.Normal }) {
          Stack({ alignContent: Alignment.TopEnd }) {
            Text(entry.edit!.kind !== 'fileTags' && this.selectedTags.includes(tag) ? `✓ ${tag}` : tag).fontSize(16).lineHeight(22)
              .fontColor(entry.edit!.kind === 'fileTags' ? UiColor.secondary : this.selectedTags.includes(tag) ? UiColor.onPrimary : UiColor.text)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 180 })
              .padding({ left: 6, right: 6, top: 3, bottom: 3 })
            if (!entry.edit!.protectedTags.includes(tag)) {
              Text('×').fontSize(12).lineHeight(14).fontColor(UiColor.secondary).hitTestBehavior(HitTestMode.None)
            }
          }
        }.height(32).padding(0).borderRadius(4).flexShrink(0)
          .backgroundColor(entry.edit!.kind === 'fileTags' ? UiColor.field : this.selectedTags.includes(tag) ? UiColor.primary : Color.Transparent)
          .id(`project_header_delete_${index}_${tag}`)
          .enabled(!this.busy && !this.saved && !entry.edit!.protectedTags.includes(tag))
          .accessibilityText(entry.edit!.protectedTags.includes(tag) ? `${tag}，不可移除` : `删除标签 ${tag}`)
          .onClick((): void => { this.removeTag(entry.id, tag) })
      }, (tag: string) => tag)
      if (this.creatingTagId === entry.id) {
        TextInput({ text: this.draft(entry.id).newTag, placeholder: '标签' }).fontSize(16).placeholderFont({ size: 16 }).placeholderColor(UiColor.secondary).fontColor(UiColor.text).height(32)
          .width(Math.min(160, Math.max(48, this.draft(entry.id).newTag.length * 16 + 16)))
          .padding({ left: 6, right: 6, top: 0, bottom: 0 }).backgroundColor(UiColor.field).borderRadius(4)
          .id(`project_header_tag_input_${index}`).enabled(!this.busy && !this.saved).defaultFocus(true)
          .onAppear((): void => { this.focusNewTag(entry.id, index) })
          .onChange((value: string): void => { this.setNewTag(entry.id, value) })
          .onBlur((): void => { this.addTag(entry.id) })
          .onSubmit((): void => { this.addTag(entry.id) })
      } else {
        Button('+', { type: ButtonType.Normal }).fontSize(20).height(32).width(32).padding(0).borderRadius(4)
          .backgroundColor(Color.Transparent).fontColor(UiColor.primary).enabled(!this.busy && !this.saved)
          .accessibilityText(`添加 ${entry.name} 标签`).id(`project_header_add_${index}`)
          .onClick((): void => { this.startTag(entry.id) })
      }
    }.width('100%').constraintSize({ minHeight: 32 })
  }

  @Builder
  inlineValue(entry: CoreFileHeaderEntry, index: number) {
    if (this.tagEditor(entry)) { this.inlineTags(entry, index) }
    else {
      Row({ space: 2 }) {
        TextInput({ text: this.draft(entry.id).text, placeholder: entry.name }).fontSize(16).placeholderFont({ size: 16 }).placeholderColor(UiColor.secondary).fontColor(UiColor.text).height(32)
          .padding({ left: 6, right: 6, top: 0, bottom: 0 }).backgroundColor(Color.Transparent).borderRadius(0).layoutWeight(1)
          .id(`project_header_value_${index}`).enabled(!this.busy && !this.saved)
          .onChange((value: string): void => { this.setText(entry.id, value) })
        if (entry.edit?.kind === 'category' && this.categoryOptions.length > 0) {
          Button({ type: ButtonType.Normal }) { Image($r('app.media.ui_down')).width(16).height(16).fillColor(UiColor.secondary) }
            .width(32).height(32).padding(0)
            .backgroundColor(Color.Transparent).fontColor(UiColor.secondary).enabled(!this.busy && !this.saved)
            .accessibilityText('选择已有分类')
            .bindMenu(this.categoryOptions.map((value: string): MenuElement => ({ value,
              action: (): void => { this.setText(entry.id, value) } })))
        }
      }.width('100%').alignItems(VerticalAlign.Center)
    }
  }

  build() {
    Column({ space: 0 }) {
      ForEach(this.entries(), (entry: CoreFileHeaderEntry, index: number) => {
        Row({ space: 12 }) {
          Text(`${this.label(entry)}:`).fontSize(16).lineHeight(22).fontColor(UiColor.disabled)
            .width(96).wordBreak(WordBreak.BREAK_ALL).padding({ top: 3, bottom: 3 }).flexShrink(0)
          Column() {
            if (this.editing && entry.edit) { this.inlineValue(entry, index) }
            else if (entry.keyword && entry.name.toUpperCase() === 'CATEGORY' && entry.value === this.category && this.category) {
              this.categoryValue(this.category)
            } else if (entry.keyword && entry.name.toUpperCase() === 'TAGS') {
              Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(2), cross: LengthMetrics.vp(2) } }) {
                ForEach(this.tagsForEntry(entry), (tag: string) => { this.tagChip(tag) }, (tag: string) => tag)
              }.width('100%').constraintSize({ minHeight: 32 })
            } else if (entry.keyword && entry.name.toUpperCase() === 'FILETAGS' && entry.tags.length > 0) {
              Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(4), cross: LengthMetrics.vp(4) } }) {
                ForEach(entry.tags, (tag: string) => { this.fileTag(tag) }, (tag: string) => tag)
              }.width('100%').padding({ top: 1, bottom: 1 })
            } else {
              Text(entry.value).fontSize(16).lineHeight(22).fontColor(UiColor.text).wordBreak(WordBreak.BREAK_ALL)
                .width('100%').padding({ left: 6, right: 6, top: 3, bottom: 3 })
            }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').alignItems(VerticalAlign.Top).constraintSize({ minHeight: 36 })
          .padding({ top: 2, bottom: 2 }).id(`project_property_${index}`)
      }, (entry: CoreFileHeaderEntry, index: number) => `${this.editing ? 'edit' : 'read'}:${entry.id}:${index}`)
      if (this.editing) {
        Row() {
          Text('编辑中').fontSize(16).fontColor(UiColor.secondary).layoutWeight(1)
          Button('取消', { type: ButtonType.Normal }).fontSize(16).height(32).backgroundColor(Color.Transparent)
            .fontColor(UiColor.secondary).enabled(!this.busy).id('project_header_cancel').onClick((): void => { this.closeEditor() })
          Button(this.busy ? '保存中' : this.saved ? '结束编辑' : '保存', { type: ButtonType.Normal }).fontSize(16).height(32)
            .backgroundColor(Color.Transparent).fontColor(UiColor.primary).enabled(!this.busy)
            .id('project_header_save').onClick((): void => { this.submitEditor() })
        }.width('100%').margin({ top: 4 })
      }
      if (this.editing && this.sourceVersion !== this.fileVersion && !this.saved) {
        Text('文件已有新版本，当前修改已保留；请取消后重新进入编辑。').fontSize(12).fontColor(UiColor.warning).width('100%').margin({ top: 8 })
      }
      if (this.editing && this.message) { Text(this.message).fontSize(12).fontColor(UiColor.error).width('100%').margin({ top: 8 }) }
    }.width('100%').padding({ left: 4, right: 4, top: 8, bottom: 16 }).alignItems(HorizontalAlign.Start)
      .id('project_properties')
      .onTouch((_event: TouchEvent): void => { if (this.editing) LinkEditController.protectInteraction() })
      .onClick((): void => { LinkEditController.protectInteraction() })
      .priorityGesture(LongPressGesture({ duration: 500, repeat: false }).tag('project_properties_edit').onAction((): void => { this.openEditor() }), GestureMask.Normal)
      .onGestureJudgeBegin((info: GestureInfo): GestureJudgeResult =>
        info.tag === 'project_properties_edit' && this.editing ? GestureJudgeResult.REJECT : GestureJudgeResult.CONTINUE)
  }
}
