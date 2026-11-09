import { UiColor } from '../ui/Theme'

@CustomDialog
export struct TaskTagsDialog {
  controller: CustomDialogController
  options: string[] = []
  ownTags: string[] = []
  inheritedTags: string[] = []
  change: (tags: string[]) => Promise<boolean> = async () => false
  @State names: string[] = []
  @State selected: string[] = []
  @State creating: boolean = false
  @State name: string = ''
  @State busy: boolean = false
  @State message: string = ''

  aboutToAppear() { this.names = [...this.options]; this.selected = [...this.ownTags] }
  async toggle(tag: string) {
    if (this.busy || this.inheritedTags.includes(tag)) return
    await this.apply(this.selected.includes(tag) ? this.selected.filter(item => item !== tag) : [...this.selected, tag])
  }
  async apply(tags: string[]): Promise<boolean> {
    this.busy = true; this.message = ''
    try {
      if (!await this.change(tags)) { this.message = '未能修改，请检查任务卡片上的错误提示'; return false }
      this.selected = tags
      return true
    } finally { this.busy = false }
  }
  async create() {
    const name = this.name.trim()
    if (!name || this.busy) return
    if (await this.apply(this.selected.includes(name) ? this.selected : [...this.selected, name])) {
      if (!this.names.includes(name)) this.names = [...this.names, name]
      this.name = ''; this.creating = false
    }
  }
  build() {
    Column({ space: 8 }) {
      Row() {
        if (this.creating) {
          Button('×').width(44).height(44).backgroundColor(Color.Transparent).fontColor(UiColor.secondary).fontSize(24)
            .enabled(!this.busy).accessibilityText('取消新建标签').onClick(() => { this.creating = false; this.name = ''; this.message = '' })
        } else { Blank().width(44) }
        Text(this.creating ? '新建标签' : '标签').layoutWeight(1).textAlign(TextAlign.Center).fontSize(17).fontColor(UiColor.text)
        Button('✓').id('inline_tags_done').width(44).height(44).fontColor(UiColor.onPrimary).backgroundColor(UiColor.primary).fontSize(20)
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
          Column() {
            ForEach(this.names, (tag: string) => {
              Row({ space: 8 }) {
                Image($r('app.media.ui_tags')).width(18).height(18)
                Text(tag).fontSize(15).fontColor(UiColor.text).layoutWeight(1).wordBreak(WordBreak.BREAK_ALL)
                if (this.inheritedTags.includes(tag)) {
                  Text('继承').fontSize(11).fontColor(UiColor.secondary)
                }
                Text(this.selected.includes(tag) || this.inheritedTags.includes(tag) ? '✓' : '').width(24)
                  .fontSize(18).fontColor(UiColor.primary)
              }.id(`inline_tag_${tag}`).width('100%').constraintSize({ minHeight: 44 }).padding({ top: 8, bottom: 8 })
                .enabled(!this.busy).accessibilityText(`${tag}${this.inheritedTags.includes(tag) ? '，从父标题继承' : this.selected.includes(tag) ? '，已选中' : '，未选择'}`)
                .onClick(() => { this.toggle(tag) })
            }, (tag: string) => tag)
          }.width('100%')
        }.width('100%').constraintSize({ maxHeight: 360 })
        Button('+ 新建标签').id('inline_tag_create').width('100%').height(40).backgroundColor(UiColor.field).fontColor(UiColor.text)
          .enabled(!this.busy).onClick(() => { this.creating = true })
      }
      if (this.message) { Text(this.message).fontSize(13).fontColor(UiColor.error).width('100%') }
    }.width('90%').constraintSize({ maxWidth: 360 }).padding(16).backgroundColor('#262B2D').borderRadius(20)
  }
}
