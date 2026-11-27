import { localizedText } from '../ui/LocalizedText'
import { common } from '@kit.AbilityKit'
import { ConfigTransfer } from '../services/ConfigTransfer'
import { PageNavigator } from '../services/PageNavigator'
import { addRepository } from '../services/RepositoryNavigation'
import { UiColor } from '../ui/Theme'
import { SettingsRow } from './controls/SettingsRow'

@Component
export struct RepositoryWelcome {
  @State selectingBackup: boolean = false
  private active: boolean = true

  aboutToAppear(): void { this.active = true }
  aboutToDisappear(): void { this.active = false }

  private async importBackup(): Promise<void> {
    if (this.selectingBackup) return
    this.selectingBackup = true
    const ui = this.getUIContext()
    const source = PageNavigator.shared.path
    try {
      const uri = await ConfigTransfer.selectFile(ui.getHostContext()! as common.UIAbilityContext)
      if (this.active && PageNavigator.shared.path === source && uri) {
        await PageNavigator.shared.pushPage(ui, { url: 'pages/ConfigImport', params: { configImportUri: uri } })
      }
    } catch (_) {
      if (this.active && PageNavigator.shared.path === source) {
        try { ui.getPromptAction().showToast({ message: localizedText($r('app.string.text_cannot_select_profile_please_try_again')) }) }
        catch (_) { /* 页面退出后不再显示提示。 */ }
      }
    } finally { this.selectingBackup = false }
  }

  build() {
    Scroll() {
      Column({ space: 20 }) {
        Text($r('app.string.text_repository_not_configured_yet')).fontSize(18).fontColor(UiColor.secondary)
          .width('100%').textAlign(TextAlign.Center)
        Column({ space: 12 }) {
          Button($r('app.string.text_initialize_a_new_repository')).width('100%').constraintSize({ minHeight: 48 }).borderRadius(12)
            .fontSize(16).backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary)
            .onClick((): void => { addRepository(this.getUIContext(), 'initialize') })
          Column() {
            SettingsRow({ title: localizedText($r('app.string.text_add_remote_repository')), value: 'WebDAV',
              action: (): void => { addRepository(this.getUIContext(), 'remote') } })
            SettingsRow({ title: localizedText($r('app.string.text_import_backup_configuration')), divider: false,
              action: (): void => { this.importBackup() } })
          }.width('100%').backgroundColor(UiColor.container).borderRadius(12).clip(true)
        }.width('100%').enabled(!this.selectingBackup)
      }.width('100%').constraintSize({ maxWidth: 400 }).padding({ left: 24, right: 24, top: 24, bottom: 24 })
    }.width('100%').height('100%').align(Alignment.Center).scrollBar(BarState.Off)
  }
}
