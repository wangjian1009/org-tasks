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
      Row({ space: 8 }) {
        Text('添加备注').fontSize(18).fontColor(UiColor.text).layoutWeight(1)
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ui_close')).width(20).height(20)
        }.id('inline_note_close').width(44).height(44).backgroundColor(Color.Transparent)
          .accessibilityText(this.stateChange ? '不添加备注，继续修改状态' : '关闭备注窗口')
          .onClick(() => { this.finish(undefined) })
      }.width('100%')
      if (this.stateChange) {
        Text('此状态设置了备注提示，关闭窗口将不添加备注并继续修改状态').fontSize(13).fontColor(UiColor.secondary).width('100%')
      }
      TextArea({ text: this.note, placeholder: '输入备注' }).id('inline_note_input')
        .height(144).fontSize(16).fontColor(UiColor.text).backgroundColor(UiColor.field)
        .defaultFocus(true).onChange((value: string): void => { this.note = value })
      Button('添加').id('inline_note_confirm').width('100%').height(44)
        .fontColor(UiColor.onPrimary).backgroundColor(UiColor.primary).enabled(this.note.trim().length > 0)
        .onClick(() => { this.finish(this.note) })
    }.padding(20).width('100%').backgroundColor(UiColor.dialog).borderRadius(16)
  }
}
