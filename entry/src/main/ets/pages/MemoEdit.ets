import { localizedText } from '../ui/LocalizedText'
import { showDangerousConfirmation } from '../components/controls/DangerousConfirmation'
import { MemoNavigation } from '../services/MemoNavigation'
import { PageNavigator } from '../services/PageNavigator'
import { CoreTask } from '../services/NativeCoreService'
import { NoteService } from '../services/NoteService'
import { MemoEditor } from '../components/editors/MemoEditor'
import { CoreNotificationsView } from '../components/CoreNotificationsView'
import { NotificationManager } from '../services/NotificationManager'
import { CoreBridgeError, coreErrorMessage } from '../services/NativeCoreService'
import { EmptyState } from '../components/controls/EmptyState'
import { UiColor } from '../ui/Theme'

interface MemoParams { task?: CoreTask; create?: boolean; memoId?: string }

@Entry({ useSharedStorage: true })
@Component
struct MemoEdit {
  @State showNotifications: boolean = false
  private stopNotifications: (() => void) | undefined = undefined
  @LocalStorageProp('entryMemoId') entryMemoId: string = ''
  @LocalStorageProp('entryMemoCreate') entryMemoCreate: boolean = false
  @State loadingMemo: boolean = false
  private memoRequest: number = 0
  @State memo: CoreTask | undefined = undefined
  @State heading: string = ''
  @State body: string = ''
  @State creating: boolean = false
  @State committed: boolean = false
  @State working: boolean = false
  @State message: string = ''

  aboutToAppear() {
    this.stopNotifications = NotificationManager.watchVisibility(visible => { this.showNotifications = visible })
    const routeParams = this.getUIContext().getRouter().getParams() as MemoParams | undefined
    const params: MemoParams = routeParams && Object.keys(routeParams).length > 0 ? routeParams :
      { create: this.entryMemoCreate, memoId: this.entryMemoId }
    this.memo = params?.task
    this.creating = params?.create === true
    this.heading = this.memo?.heading || ''
    this.body = this.memo?.body || ''
    if (!this.memo && !this.creating && params.memoId) this.loadMemo(params.memoId)
  }

  async loadMemo(memoId: string): Promise<void> {
    const request = ++this.memoRequest
    this.loadingMemo = true
    try {
      const task = await MemoNavigation.find(this.getUIContext().getHostContext()!, memoId)
      if (request !== this.memoRequest) return
      if (!task) { this.message = localizedText($r('app.string.text_this_note_has_been_changed_or_deleted')); return }
      this.memo = task; this.heading = task.heading; this.body = task.body
    } catch (_) {
      if (request === this.memoRequest) this.message = localizedText($r('app.string.text_couldn_t_load_the_note_return_to'))
    } finally { if (request === this.memoRequest) this.loadingMemo = false }
  }

  private stopExternalGuard: (() => void) | undefined = undefined
  onPageShow() {
    this.stopExternalGuard?.()
    this.stopExternalGuard = PageNavigator.shared.watchExternalLeaveGuard((): boolean =>
      !this.working && !this.loadingMemo && (this.committed || this.heading === (this.memo?.heading || '') && this.body === (this.memo?.body || '')))
  }
  onPageHide(): void { this.stopExternalGuard?.(); this.stopExternalGuard = undefined }
  aboutToDisappear(): void {
    this.stopNotifications?.()
    this.stopNotifications = undefined
    this.memoRequest++; this.stopExternalGuard?.()
  }

  onBackPress(): boolean {
    this.saveAndBack(true)
    return true
  }

  async saveAndBack(discardEmpty: boolean = false) {
    if (this.working) return
    if (this.loadingMemo) { this.memoRequest++; this.loadingMemo = false }
    const leavingEmpty = discardEmpty && this.creating && !this.heading && !this.body
    if (!this.committed && !leavingEmpty && (this.memo || this.creating) && this.heading.trim().length === 0) {
      this.message = localizedText($r('app.string.text_title_cannot_be_empty'))
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
      await PageNavigator.shared.back(this.getUIContext())
    } catch (e) {
      this.message = `${this.committed ? localizedText($r('app.string.note_saved_return_failed')) : localizedText($r('app.string.text_couldn_t_save_the_note'))}：${coreErrorMessage(e as CoreBridgeError)}`
    } finally {
      this.working = false
    }
  }

  confirmDelete() {
    if (!this.memo || this.working || this.committed) return
    showDangerousConfirmation(this.getUIContext(), {
      title: localizedText($r('app.string.text_delete_this_note')),
      message: localizedText($r('app.string.text_will_be_moved_to_the_waste_paper'), String(this.memo.heading)),
      confirmLabel: localizedText($r('app.string.text_delete')), onConfirm: (): void => { this.deleteMemo() }
    })
  }

  async deleteMemo() {
    if (!this.memo || this.working || this.committed) return
    this.working = true
    this.message = ''
    try {
      await NoteService.remove(this.getUIContext().getHostContext()!, this.memo!)
      this.committed = true
      await PageNavigator.shared.back(this.getUIContext())
    } catch (e) {
      this.message = `${this.committed ? localizedText($r('app.string.note_deleted_return_failed')) : localizedText($r('app.string.text_couldn_t_delete_the_note'))}：${coreErrorMessage(e as CoreBridgeError)}`
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
          .accessibilityText($r('app.string.text_back')).enabled(!this.working).onClick((): void => { this.saveAndBack(true) })
        TextInput({ text: this.heading, placeholder: localizedText($r('app.string.text_title')) }).height(48).layoutWeight(1)
          .margin({ left: 12 }).padding({ left: 0, right: 0 }).fontSize(16).fontColor(UiColor.text)
          .placeholderColor(UiColor.secondary).backgroundColor(Color.Transparent)
          .enabled(!this.loadingMemo && !this.working && !this.committed).onChange((value: string): void => { this.heading = value })
        if (this.creating) {
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.ui_done')).width(24).height(24)
          }.width(48).height(48).padding(0).backgroundColor(Color.Transparent).borderRadius(0)
            .accessibilityText($r('app.string.text_save_note')).enabled(!this.working)
            .onClick((): void => { this.saveAndBack() })
        } else {
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.ui_delete')).width(24).height(24)
          }.width(48).height(48).padding(0).backgroundColor(Color.Transparent).borderRadius(0)
            .accessibilityText($r('app.string.text_delete')).enabled(!this.working && !this.committed && this.memo !== undefined)
            .onClick((): void => { this.confirmDelete() })
        }
      }.width('100%').height(64).padding({ left: 4, right: 4 }).alignItems(VerticalAlign.Center)
        .backgroundColor(UiColor.surface)
      Divider().color(UiColor.outline).strokeWidth(0.5)
      if (this.showNotifications) {
        CoreNotificationsView({ disabled: this.working || this.committed })
          .margin({ bottom: 12 })
      }
      if (this.message.length > 0) {
        Text(this.message).width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .fontSize(13).fontColor(UiColor.error).backgroundColor(UiColor.container)
      }
      if (this.loadingMemo) {
        EmptyState({ title: localizedText($r('app.string.text_reading_memo_2')), busy: true })
      } else if (!this.memo && !this.creating) {
        EmptyState({ title: localizedText($r('app.string.text_couldn_t_open_this_note')), detail: localizedText($r('app.string.text_re_select_from_the_memo_list')),
          actionLabel: localizedText($r('app.string.notes_back_to_list')), action: (): void => { this.saveAndBack(true) } })
      } else {
        MemoEditor({ task: this.memo, editable: true, disabled: this.working || this.committed, bodyValue: this.body,
          bodyChanged: (value: string): void => { this.body = value } })
          .width('100%').layoutWeight(1)
      }
    }.width('100%').height('100%').backgroundColor(UiColor.surface)
  }
}
