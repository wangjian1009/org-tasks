import { UiColor } from '../ui/Theme'
import { CoreSupportTags } from '../services/NativeCoreService'
import { editableTagNames, editableTagGroups, selectedTagNames, inheritedTagConflict, toggleEditableTag } from '../ui/TaskTagsPresentation'

@CustomDialog
export struct TaskTagsDialog {
  controller: CustomDialogController
  supportTags: CoreSupportTags | null = null
  ownTags: string[] = []
  visibleTags: string[] = []
  inheritedTags: string[] = []
  hiddenTags: string[] = []
  change: (tags: string[]) => Promise<boolean> = async () => false
  @State names: string[] = []
  @State selected: string[] = []
  @State creating: boolean = false
  @State name: string = ''
  @State busy: boolean = false
  @State message: string = ''

  aboutToAppear() {
    this.names = editableTagNames(this.supportTags, this.visibleTags, this.inheritedTags).filter(tag => !this.hiddenTags.includes(tag))
    this.selected = [...this.ownTags]
  }
  selectedNames(): string[] {
    return selectedTagNames(this.selected, this.inheritedTags, this.names).filter(tag => !this.hiddenTags.includes(tag))
  }
  async toggle(tag: string) {
    if (this.busy || this.inheritedTags.includes(tag)) return
    const inherited = inheritedTagConflict(tag, this.inheritedTags, this.supportTags)
    if (!this.selected.includes(tag) && inherited) { this.message = `该组已继承“${inherited}”，请在父标题修改`; return }
    await this.apply(toggleEditableTag(this.selected, tag, this.supportTags))
  }
  async apply(tags: string[]): Promise<boolean> {
    this.busy = true; this.message = ''
    const next = Array.from(new Set<string>([...tags, ...this.ownTags.filter(tag => this.hiddenTags.includes(tag))]))
    try {
      if (!await this.change(next)) { this.message = '未能修改，请检查任务卡片上的错误提示'; return false }
      this.selected = next
      return true
    } finally { this.busy = false }
  }
  async create() {
    const name = this.name.trim()
    if (!name || this.busy) return
    if (this.hiddenTags.includes(name)) { this.message = '该标签由系统管理'; return }
    if (this.inheritedTags.includes(name)) { this.message = '该标签已从父标题继承'; return }
    const inherited = inheritedTagConflict(name, this.inheritedTags, this.supportTags)
    if (inherited) { this.message = `该组已继承“${inherited}”，请在父标题修改`; return }
    if (await this.apply(this.selected.includes(name) ? this.selected : toggleEditableTag(this.selected, name, this.supportTags))) {
      if (!this.names.includes(name)) this.names = [...this.names, name]
      this.name = ''; this.creating = false
    }
  }
  @Builder
  tagChip(tag: string, selectedArea: boolean = false) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 4 }) {
        Text(tag).fontSize(14).fontColor(this.selected.includes(tag) || this.inheritedTags.includes(tag) ? UiColor.primary : UiColor.secondary)
          .wordBreak(WordBreak.BREAK_ALL)
        if (this.inheritedTags.includes(tag)) { Text('继承').fontSize(10).fontColor(UiColor.secondary) }
      }.constraintSize({ minHeight: 32, maxWidth: '100%' }).padding({ left: 12, right: 12, top: 5, bottom: 5 })
        .backgroundColor(this.selected.includes(tag) || this.inheritedTags.includes(tag) ? '#1F382E' : UiColor.field).borderRadius(16)
    }.id(selectedArea ? `inline_selected_tag_${tag}` : `inline_tag_${tag}`)
      .constraintSize({ minHeight: 44, maxWidth: '100%' }).padding(0).backgroundColor(Color.Transparent)
      .margin({ right: 8, bottom: 4 }).enabled(!this.busy)
      .accessibilityText(`${tag}${this.inheritedTags.includes(tag) ? '，从父标题继承' : this.selected.includes(tag) ? '，已选中' : '，未选择'}`)
      .onClick(() => { this.toggle(tag) })
  }
  build() {
    Column({ space: 8 }) {
      Row() {
        if (this.creating) {
          Button({ type: ButtonType.Normal }) { Image($r('app.media.ui_close')).width(20).height(20) }
            .width(44).height(44).backgroundColor(Color.Transparent)
            .enabled(!this.busy).accessibilityText('取消新建标签').onClick(() => { this.creating = false; this.name = ''; this.message = '' })
        } else { Blank().width(44) }
        Text(this.creating ? '新建标签' : '标签').layoutWeight(1).textAlign(TextAlign.Center).fontSize(17).fontColor(UiColor.text)
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ui_done')).width(20).height(20)
        }.id('inline_tags_done').width(44).height(44).backgroundColor(Color.Transparent)
          .enabled(!this.busy && (!this.creating || this.name.trim().length > 0))
          .accessibilityText(this.creating ? '创建并添加标签' : '关闭标签窗口')
          .onClick(() => { if (this.creating) this.create(); else this.controller.close() })
      }.width('100%')
      if (this.creating) {
        TextInput({ text: this.name, placeholder: '标签名称' }).id('inline_new_tag').defaultFocus(true)
          .fontSize(16).fontColor(UiColor.text).backgroundColor(UiColor.field).enabled(!this.busy)
          .onChange((value: string) => { this.name = value }).onSubmit(() => { this.create() })
        Text('创建后添加到当前任务').fontSize(12).fontColor(UiColor.secondary).width('100%')
      } else {
        Scroll() {
          Column({ space: 8 }) {
            if (this.selectedNames().length > 0) {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.selectedNames(), (tag: string) => {
                  this.tagChip(tag, true)
                }, (tag: string) => tag)
              }.width('100%')
              Divider().color(UiColor.outline)
            }
            Text('全部标签').fontSize(13).fontColor(UiColor.secondary).width('100%')
            ForEach(editableTagGroups(this.names, this.supportTags), (group: string[], index: number) => {
              if (index > 0) { Divider().color(UiColor.outline).margin({ bottom: 8 }) }
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(group, (tag: string) => { this.tagChip(tag) }, (tag: string) => tag)
              }.width('100%')
            }, (group: string[]) => JSON.stringify(group))
            if (this.names.length === 0) { Text('暂无标签，可点击下方新建标签添加').fontSize(13).fontColor(UiColor.secondary).width('100%') }
          }.width('100%')
        }.width('100%').constraintSize({ maxHeight: 360 })
        Button('新建标签…').id('inline_tag_create').width('100%').height(44).backgroundColor(UiColor.field).fontColor(UiColor.text)
          .enabled(!this.busy).onClick(() => { this.creating = true })
      }
      if (this.message) { Text(this.message).fontSize(13).fontColor(UiColor.error).width('100%') }
    }.width('calc(100% - 32vp)').constraintSize({ maxWidth: 360 })
      .padding(16).backgroundColor(UiColor.dialog).borderRadius(20)
  }
}
