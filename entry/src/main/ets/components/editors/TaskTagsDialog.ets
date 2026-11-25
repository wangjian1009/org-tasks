import { localizedText } from '../../ui/LocalizedText'
import { UiColor } from '../../ui/Theme'
import { CoreSupportTags, CoreTaskModification } from '../../services/NativeCoreService'
import { editableTagNames, editableTagGroups, selectedTagNames, inheritedTagConflict, toggleEditableTag } from '../../ui/TaskTagsPresentation'

@CustomDialog
export struct TaskTagsDialog {
  controller: CustomDialogController
  supportTags: CoreSupportTags | null = null
  ownTags: string[] = []
  visibleTags: string[] = []
  inheritedTags: string[] = []
  hiddenTags: string[] = []
  closeOnConfirm: boolean = true
  changed: (modification: CoreTaskModification) => void = () => {}
  confirmed: (modification: CoreTaskModification) => void = () => {}
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
  toggle(tag: string) {
    if (this.busy || this.inheritedTags.includes(tag)) return
    const inherited = inheritedTagConflict(tag, this.inheritedTags, this.supportTags)
    if (!this.selected.includes(tag) && inherited) { this.message = localizedText($r('app.string.text_this_group_has_inherited_please_change_under'), String(inherited)); return }
    this.apply(toggleEditableTag(this.selected, tag, this.supportTags))
  }
  apply(tags: string[]): boolean {
    this.message = ''
    const next = Array.from(new Set<string>([...tags, ...this.ownTags.filter(tag => this.hiddenTags.includes(tag))]))
    this.selected = next
    this.changed({ field: 'TAGS', value: [...next] })
    return true
  }
  accept(): void {
    this.confirmed({ field: 'TAGS', value: [...this.selected] })
    if (this.closeOnConfirm) this.controller.close()
  }
  create() {
    const name = this.name.trim()
    if (!name || this.busy) return
    if (this.hiddenTags.includes(name)) { this.message = localizedText($r('app.string.text_this_label_is_managed_by_the_system')); return }
    if (this.inheritedTags.includes(name)) { this.message = localizedText($r('app.string.text_the_label_has_been_inherited_from_the')); return }
    const inherited = inheritedTagConflict(name, this.inheritedTags, this.supportTags)
    if (inherited) { this.message = localizedText($r('app.string.text_this_group_has_inherited_please_change_under'), String(inherited)); return }
    if (this.apply(this.selected.includes(name) ? this.selected : toggleEditableTag(this.selected, name, this.supportTags))) {
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
        if (this.inheritedTags.includes(tag)) { Text($r('app.string.text_succession')).fontSize(10).fontColor(UiColor.secondary) }
      }.constraintSize({ minHeight: 32, maxWidth: '100%' }).padding({ left: 12, right: 12, top: 5, bottom: 5 })
        .backgroundColor(this.selected.includes(tag) || this.inheritedTags.includes(tag) ? '#1F382E' : UiColor.field).borderRadius(16)
    }.id(selectedArea ? `inline_selected_tag_${tag}` : `inline_tag_${tag}`)
      .constraintSize({ minHeight: 44, maxWidth: '100%' }).padding(0).backgroundColor(Color.Transparent)
      .margin({ right: 8, bottom: 4 }).enabled(!this.busy)
      .accessibilityText(`${tag}${this.inheritedTags.includes(tag) ? localizedText($r('app.string.text_from_the_parent_title')) : this.selected.includes(tag) ? localizedText($r('app.string.text_selected_2')) : localizedText($r('app.string.text_no_selection_2'))}`)
      .onClick(() => { this.toggle(tag) })
  }
  build() {
    Column({ space: 8 }) {
      Row() {
        if (this.creating) {
          Button({ type: ButtonType.Normal }) { Image($r('app.media.ui_close')).width(20).height(20) }
            .width(44).height(44).backgroundColor(Color.Transparent)
            .enabled(!this.busy).accessibilityText($r('app.string.text_cancel_new_tab')).onClick(() => { this.creating = false; this.name = ''; this.message = '' })
        } else { Blank().width(44) }
        Text(this.creating ? localizedText($r('app.string.text_new_tab')) : localizedText($r('app.string.text_tags'))).layoutWeight(1).textAlign(TextAlign.Center).fontSize(17).fontColor(UiColor.text)
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ui_done')).width(20).height(20)
        }.id('inline_tags_done').width(44).height(44).backgroundColor(Color.Transparent)
          .enabled(!this.busy && (!this.creating || this.name.trim().length > 0))
          .accessibilityText(this.creating ? localizedText($r('app.string.text_create_and_add_labels')) : localizedText($r('app.string.text_close_tab_window')))
          .onClick(() => { if (this.creating) this.create(); else this.accept() })
      }.width('100%')
      if (this.creating) {
        TextInput({ text: this.name, placeholder: localizedText($r('app.string.text_tab_name')) }).id('inline_new_tag').defaultFocus(true)
          .fontSize(16).fontColor(UiColor.text).backgroundColor(UiColor.field).enabled(!this.busy)
          .onChange((value: string) => { this.name = value }).onSubmit(() => { this.create() })
        Text($r('app.string.text_add_to_current_task_after_creation')).fontSize(12).fontColor(UiColor.secondary).width('100%')
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
            Text($r('app.string.text_all_tags')).fontSize(13).fontColor(UiColor.secondary).width('100%')
            ForEach(editableTagGroups(this.names, this.supportTags), (group: string[], index: number) => {
              if (index > 0) { Divider().color(UiColor.outline).margin({ bottom: 8 }) }
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(group, (tag: string) => { this.tagChip(tag) }, (tag: string) => tag)
              }.width('100%')
            }, (group: string[]) => JSON.stringify(group))
            if (this.names.length === 0) { Text($r('app.string.text_unlabeled_tap_to_add_a_new_tab')).fontSize(13).fontColor(UiColor.secondary).width('100%') }
          }.width('100%')
        }.width('100%').constraintSize({ maxHeight: 360 })
        Button($r('app.string.text_new_tab_2')).id('inline_tag_create').width('100%').height(44).backgroundColor(UiColor.field).fontColor(UiColor.text)
          .enabled(!this.busy).onClick(() => { this.creating = true })
      }
      if (this.message) { Text(this.message).fontSize(13).fontColor(UiColor.error).width('100%') }
    }.width('calc(100% - 32vp)').constraintSize({ maxWidth: 360 })
      .padding(16).backgroundColor(UiColor.dialog).borderRadius(20)
  }
}
