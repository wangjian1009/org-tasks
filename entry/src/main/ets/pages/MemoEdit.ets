import { CoreTask } from '../services/NativeCoreService'
import { NoteService } from '../services/NoteService'
import { MemoEditor } from '../components/MemoEditor'
import { CoreNotificationsView } from '../components/CoreNotificationsView'
import { CoreNotificationService, CoreNotificationsState, emptyCoreNotificationsState } from '../services/CoreNotificationService'
import { CoreBridgeError, coreErrorMessage } from '../services/NativeCoreService'
import { EmptyState } from '../components/Controls'
import { UiColor } from '../ui/Theme'

interface MemoParams { task?: CoreTask; create?: boolean }

@Entry
@Component
struct MemoEdit {
  @StorageLink('coreNotifications') notificationState: CoreNotificationsState = emptyCoreNotificationsState()
  @State memo: CoreTask | undefined = undefined
  @State heading: string = ''
  @State body: string = ''
  @State creating: boolean = false
  @State committed: boolean = false
  @State working: boolean = false
  @State message: string = ''

  aboutToAppear() {
    const params = this.getUIContext().getRouter().getParams() as MemoParams | undefined
    this.memo = params?.task
    this.creating = params?.create === true
    this.heading = this.memo?.heading || ''
    this.body = this.memo?.body || ''
  }

  onPageShow() { this.refreshNotifications() }

  async refreshNotifications() {
    try {
      await CoreNotificationService.refresh(this.getUIContext().getHostContext()!)
    } catch (e) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: `读取通知失败：${coreErrorMessage(e as CoreBridgeError)}` })
      } catch (_) { console.error('显示备忘通知读取错误失败') }
    }
  }

  onBackPress(): boolean {
    this.saveAndBack(true)
    return true
  }

  async saveAndBack(discardEmpty: boolean = false) {
    if (this.working) return
    const leavingEmpty = discardEmpty && this.creating && !this.heading && !this.body
    if (!this.committed && !leavingEmpty && (this.memo || this.creating) && this.heading.trim().length === 0) {
      this.message = '标题不能为空'
      return
    }
    this.working = true
    this.message = ''
    try {
      const context = this.getUIContext().getHostContext()!
      if (!this.committed && !leavingEmpty) {
        if (this.creating) await NoteService.createMemo(context, this.heading, this.body)
        else if (this.memo) await NoteService.update(context, this.memo, this.heading, this.body)
        this.committed = true
      }
      await this.getUIContext().getRouter().back()
    } catch (e) {
      this.message = `${this.committed ? '备忘已保存，返回失败' : '保存备忘失败'}：${coreErrorMessage(e as CoreBridgeError)}`
    } finally {
      this.working = false
    }
  }

  confirmDelete() {
    if (!this.memo || this.working || this.committed) return
    this.getUIContext().showAlertDialog({
      title: '删除备忘？',
      message: `“${this.memo.heading}”及其子记录将从文件中删除。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', action: (): void => { this.deleteMemo() } }
    })
  }

  async deleteMemo() {
    if (!this.memo || this.working || this.committed) return
    this.working = true
    this.message = ''
    try {
      await NoteService.remove(this.getUIContext().getHostContext()!, this.memo!)
      this.committed = true
      await this.getUIContext().getRouter().back()
    } catch (e) {
      this.message = `${this.committed ? '备忘已删除，返回失败' : '删除备忘失败'}：${coreErrorMessage(e as CoreBridgeError)}`
    } finally {
      this.working = false
    }
  }

  build() {
    Column() {
      Row() {
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ui_back')).width(24).height(24)
        }.width(56).height(48).padding(0).backgroundColor(Color.Transparent).borderRadius(0)
          .accessibilityText('返回').enabled(!this.working).onClick((): void => { this.saveAndBack(true) })
        TextInput({ text: this.heading, placeholder: '标题' }).height(48).layoutWeight(1)
          .margin({ left: 12 }).padding({ left: 0, right: 0 }).fontSize(22).fontColor(UiColor.text)
          .placeholderColor(UiColor.secondary).backgroundColor(Color.Transparent)
          .enabled(!this.working && !this.committed).onChange((value: string): void => { this.heading = value })
        if (this.creating) {
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.ui_done')).width(24).height(24)
          }.width(48).height(48).padding(0).backgroundColor(Color.Transparent).borderRadius(0)
            .accessibilityText('保存备忘').enabled(!this.working)
            .onClick((): void => { this.saveAndBack() })
        } else {
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.ui_delete')).width(24).height(24)
          }.width(48).height(48).padding(0).backgroundColor(Color.Transparent).borderRadius(0)
            .accessibilityText('删除').enabled(!this.working && !this.committed && this.memo !== undefined)
            .onClick((): void => { this.confirmDelete() })
        }
      }.width('100%').height(64).padding({ left: 4, right: 4 }).alignItems(VerticalAlign.Center)
        .backgroundColor(UiColor.surface)
      Divider().color(UiColor.outline).strokeWidth(0.5)
      if (this.notificationState.notifications.length > 0) {
        CoreNotificationsView({ disabled: this.working || this.committed })
          .margin({ bottom: 12 })
      }
      if (this.message.length > 0) {
        Text(this.message).width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .fontSize(13).fontColor(UiColor.error).backgroundColor(UiColor.container)
      }
      if (!this.memo && !this.creating) {
        EmptyState({ title: '无法打开此备忘', detail: '请从备忘列表进入。' })
      } else {
        MemoEditor({ task: this.memo, editable: true, disabled: this.working || this.committed, bodyValue: this.body,
          bodyChanged: (value: string): void => { this.body = value } })
          .width('100%').layoutWeight(1)
      }
    }.width('100%').height('100%').backgroundColor(UiColor.surface)
  }
}
