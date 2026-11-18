import { UiColor } from '../../ui/Theme'

@CustomDialog
export struct TaskNoteDialog {
  controller: CustomDialogController
  stateChange: boolean = false
  finished: (note: string | undefined) => void = () => {}
  @State note: string = ''

  private finish(note: string | undefined): void {
    this.finished(note)
    this.controller.close()
  }

  build() {
    Column({ space: 16 }) {
      Text('添加备注').fontSize(18).fontColor(UiColor.text).width('100%')
      if (this.stateChange) {
        Text('此状态设置了备注提示，取消将继续修改状态').fontSize(13).fontColor(UiColor.secondary).width('100%')
      }
      TextArea({ text: this.note, placeholder: '输入备注' }).id('inline_note_input')
        .height(144).fontSize(16).fontColor(UiColor.text).backgroundColor(UiColor.field)
        .defaultFocus(true).onChange((value: string): void => { this.note = value })
      Row({ space: 12 }) {
        Button('取消').id('inline_note_cancel').layoutWeight(1).height(44)
          .fontColor(UiColor.secondary).backgroundColor(UiColor.field).onClick(() => { this.finish(undefined) })
        Button('添加').id('inline_note_confirm').layoutWeight(1).height(44)
          .fontColor(UiColor.onPrimary).backgroundColor(UiColor.primary).enabled(this.note.trim().length > 0)
          .onClick(() => { this.finish(this.note) })
      }.width('100%')
    }.padding(20).width('100%').backgroundColor(UiColor.dialog).borderRadius(16)
  }
}
