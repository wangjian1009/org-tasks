import { CoreTask } from '../services/NativeCoreService'
import { AppConfigService } from '../services/AppConfigService'
import { MemoEditor } from '../components/MemoEditor'
import { CoreBridgeError, NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'
import { EmptyState } from '../components/Controls'
import { UiColor } from '../ui/Theme'

interface MemoParams { task?: CoreTask }

@Entry
@Component
struct MemoEdit {
  @State memo: CoreTask | undefined = undefined
  @State heading: string = ''
  @State body: string = ''
  @State working: boolean = false
  @State message: string = ''

  aboutToAppear() {
    const params = this.getUIContext().getRouter().getParams() as MemoParams | undefined
    this.memo = params?.task
    this.heading = this.memo?.heading || ''
    this.body = this.memo?.body || ''
  }

  onBackPress(): boolean {
    this.saveAndBack()
    return true
  }

  async saveAndBack() {
    if (this.working) return
    if (!this.memo) {
      await this.getUIContext().getRouter().back()
      return
    }
    if (this.heading.trim().length === 0) {
      this.message = '标题不能为空'
      return
    }
    if (this.heading === this.memo.heading && this.body === this.memo.body) {
      await this.getUIContext().getRouter().back()
      return
    }
    this.working = true
    this.message = ''
    try {
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!, false)
      const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
      const coreRepository = (await workspace.repos()).find((repo) => repo.id === this.memo!.repoId)
      const repository = config.repos.find((repo) => repo.rootDirectory === coreRepository?.rootDirectory)
      if (!repository) throw new Error('目标仓库不可用')
      await NativeCoreService.updateTask(config.repos, repository, this.memo!.filePath, this.memo!.id,
        this.memo!.body, this.heading, this.body, config.todoDefaults)
      await this.getUIContext().getRouter().back()
    } catch (e) {
      this.message = `保存备忘失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally {
      this.working = false
    }
  }

  confirmDelete() {
    if (!this.memo || this.working) return
    this.getUIContext().showAlertDialog({
      title: '删除备忘？',
      message: `将从“${this.memo.heading}”所在文件中删除此标题及其正文。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', action: (): void => { this.deleteMemo() } }
    })
  }

  async deleteMemo() {
    if (!this.memo || this.working) return
    this.working = true
    this.message = ''
    try {
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!, false)
      const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
      const coreRepository = (await workspace.repos()).find((repo) => repo.id === this.memo!.repoId)
      const repository = config.repos.find((repo) => repo.rootDirectory === coreRepository?.rootDirectory)
      if (!repository) throw new Error('目标仓库不可用')
      await NativeCoreService.deleteTask(config.repos, repository, this.memo!.filePath, this.memo!.id,
        this.memo!.body, config.todoDefaults)
      await this.getUIContext().getRouter().back()
    } catch (e) {
      this.message = `删除备忘失败：${coreErrorMessage(e as CoreBridgeError)}`
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
          .accessibilityText('返回').enabled(!this.working).onClick((): void => { this.saveAndBack() })
        TextInput({ text: this.heading, placeholder: '标题' }).height(48).layoutWeight(1)
          .margin({ left: 12 }).padding({ left: 0, right: 0 }).fontSize(22).fontColor(UiColor.text)
          .placeholderColor(UiColor.secondary).backgroundColor(Color.Transparent)
          .enabled(!this.working).onChange((value: string): void => { this.heading = value })
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ui_delete')).width(24).height(24)
        }.width(48).height(48).padding(0).backgroundColor(Color.Transparent).borderRadius(0)
          .accessibilityText('删除').enabled(!this.working && this.memo !== undefined)
          .onClick((): void => { this.confirmDelete() })
      }.width('100%').height(64).padding({ left: 4, right: 4 }).alignItems(VerticalAlign.Center)
        .backgroundColor(UiColor.surface)
      Divider().color(UiColor.outline).strokeWidth(0.5)
      if (this.message.length > 0) {
        Text(this.message).width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .fontSize(13).fontColor(UiColor.error).backgroundColor(UiColor.container)
      }
      if (!this.memo) {
        EmptyState({ title: '无法打开此备忘', detail: '请从备忘列表进入。' })
      } else {
        MemoEditor({ task: this.memo, editable: true, bodyValue: this.body,
          bodyChanged: (value: string): void => { this.body = value } })
          .width('100%').layoutWeight(1)
      }
    }.width('100%').height('100%').backgroundColor(UiColor.surface)
  }
}
