import { CoreTask, CoreTaskModification, NativeCoreService, CoreBridgeError, coreErrorMessage } from '../services/NativeCoreService'
import { AppConfigService } from '../services/AppConfigService'
import { TaskRepeatDialog } from '../components/TaskRepeatDialog'
import { NoteService } from '../services/NoteService'
import { AppShell } from '../components/AppShell'
import { TaskEditor } from '../components/TaskEditor'
import { UiColor } from '../ui/Theme'

interface TaskParams { task?: CoreTask; parents?: string[] }

@Entry
@Component
struct TaskEdit {
  @State task: CoreTask | undefined = undefined
  @State parents: string[] = []
  @State drawerOpen: boolean = false
  @State heading: string = ''
  @State body: string = ''
  @State editing: boolean = false
  @State working: boolean = false
  @State committed: boolean = false
  @State message: string = ''
  private repeatDialog: CustomDialogController | undefined = undefined

  editRepeat() {
    if (!this.task || this.working || this.committed || this.editing) return
    this.repeatDialog = new CustomDialogController({ builder: TaskRepeatDialog({ task: this.task,
      initialDeadline: !this.task.editContent.scheduledRepeat?.rule && !!this.task.editContent.deadlineRepeat?.rule,
      save: async (changes: CoreTaskModification[]): Promise<boolean> => {
        if (!this.task) return false
        this.working = true; this.message = ''
        try {
          const context = this.getUIContext().getHostContext()!
          await NoteService.modify(context, this.task, changes)
          this.committed = true
          const config = await AppConfigService.load(context, false)
          const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
          this.task = (await workspace.fileAt(this.task.fullPath)).node(this.task.fullPath)
          this.committed = false
          return true
        } catch (error) {
          this.message = `${this.committed ? '重复规则已保存，重新读取失败，请返回列表' : '保存失败'}：${coreErrorMessage(error as CoreBridgeError)}`
          return this.committed
        } finally { this.working = false }
      } }), customStyle: true, autoCancel: true, alignment: DialogAlignment.Center,
      onWillDismiss: (action: DismissDialogAction) => { if (!this.working) action.dismiss() } })
    this.repeatDialog.open()
  }

  async changePriority(name: string | null): Promise<boolean> {
    if (!this.task || this.working || this.committed || this.editing) return false
    this.working = true; this.message = ''
    try {
      const context = this.getUIContext().getHostContext()!
      await NoteService.modify(context, this.task, [{ field: 'PRIORITY', value: name }])
      this.committed = true
      const config = await AppConfigService.load(context, false)
      const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
      this.task = (await workspace.fileAt(this.task.fullPath)).node(this.task.fullPath)
      this.committed = false
      return true
    } catch (error) {
      this.message = `${this.committed ? '优先级已保存，重新读取失败，请返回列表' : '保存失败'}：${coreErrorMessage(error as CoreBridgeError)}`
      return this.committed
    } finally { this.working = false }
  }

  aboutToAppear() {
    const params = this.getUIContext().getRouter().getParams() as TaskParams | undefined
    this.task = params?.task
    this.parents = params?.parents || []
    this.heading = this.task?.heading || ''
    this.body = this.task?.body || ''
  }

  aboutToDisappear() { this.repeatDialog?.close() }

  onBackPress(): boolean {
    this.saveAndBack()
    return true
  }

  editOrSave() {
    if (!this.task || this.working) return
    if (this.editing || this.committed) { this.saveAndBack(); return }
    this.editing = true
  }

  async saveAndBack() {
    if (this.working) return
    this.working = true
    this.message = ''
    try {
      if (this.task && this.editing && !this.committed) {
        await NoteService.update(this.getUIContext().getHostContext()!, this.task, this.heading, this.body)
        this.committed = true
      }
      await this.getUIContext().getRouter().back()
    } catch (e) {
      this.message = `${this.committed ? '操作已完成，返回失败' : '保存失败'}：${coreErrorMessage(e as CoreBridgeError)}`
    } finally { this.working = false }
  }

  confirmDelete() {
    if (!this.task || this.working || this.committed) return
    this.getUIContext().showAlertDialog({ title: '删除这条记录？',
      message: `“${this.task.heading}”及其子记录将从文件中删除。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', fontColor: UiColor.error, action: (): void => { this.deleteNote() } } })
  }

  async deleteNote() {
    if (!this.task || this.working || this.committed) return
    this.working = true
    this.message = ''
    try {
      await NoteService.remove(this.getUIContext().getHostContext()!, this.task)
      this.committed = true
      await this.getUIContext().getRouter().back()
    } catch (e) {
      this.message = `${this.committed ? '记录已删除，返回失败' : '删除失败'}：${coreErrorMessage(e as CoreBridgeError)}`
    } finally { this.working = false }
  }

  build() {
    Column() {
      AppShell({ title: '任务编辑', titleIcon: $r('app.media.ui_edit'), back: true, drawerOpen: $drawerOpen,
        busy: this.working, backAction: (): void => { this.saveAndBack() },
        actionIcon: this.editing ? $r('app.media.ui_done') : $r('app.media.ui_edit'),
        actionLabel: this.task ? (this.editing ? '保存' : '编辑') : '', action: (): void => { this.editOrSave() },
        secondaryActionIcon: $r('app.media.ui_delete'), secondaryActionLabel: this.task && !this.committed ? '删除' : '',
        secondaryAction: (): void => { this.confirmDelete() } }) {
        Column() {
          if (this.message) {
            Text(this.message).fontSize(13).fontColor(UiColor.error).padding(16).width('100%')
          }
          TaskEditor({ task: this.task, parents: this.parents, editable: this.editing,
            disabled: this.working || this.committed, headingValue: this.heading, bodyValue: this.body,
            headingChanged: (value: string): void => { this.heading = value },
            editRepeat: () => { this.editRepeat() },
            changePriority: async (name: string | null): Promise<boolean> => await this.changePriority(name),
            bodyChanged: (value: string): void => { this.body = value } }).layoutWeight(1)
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
