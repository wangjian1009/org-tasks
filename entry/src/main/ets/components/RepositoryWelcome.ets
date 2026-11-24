import { common } from '@kit.AbilityKit'
import { picker } from '@kit.CoreFileKit'
import { CONFIG_FILE_EXTENSION } from '../services/ConfigTransfer'
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
      const options = new picker.DocumentSelectOptions()
      options.maxSelectNumber = 1
      options.fileSuffixFilters = [`小清单配置文件|${CONFIG_FILE_EXTENSION}`]
      const files = await new picker.DocumentViewPicker(ui.getHostContext()! as common.UIAbilityContext).select(options)
      if (this.active && PageNavigator.shared.path === source && files.length > 0) {
        await PageNavigator.shared.pushPage(ui, { url: 'pages/ConfigImport', params: { configImportUri: files[0] } })
      }
    } catch (_) {
      if (this.active && PageNavigator.shared.path === source) {
        try { ui.getPromptAction().showToast({ message: '无法选择配置文件，请重试' }) }
        catch (_) { /* 页面退出后不再显示提示。 */ }
      }
    } finally { this.selectingBackup = false }
  }

  build() {
    Scroll() {
      Column({ space: 20 }) {
        Text('尚未配置仓库').fontSize(18).fontColor(UiColor.secondary)
          .width('100%').textAlign(TextAlign.Center)
        Column({ space: 12 }) {
          Button('初始化新仓库').width('100%').constraintSize({ minHeight: 48 }).borderRadius(12)
            .fontSize(16).backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary)
            .onClick((): void => { addRepository(this.getUIContext(), 'initialize') })
          Column() {
            SettingsRow({ title: '新增远程仓库', value: 'WebDAV',
              action: (): void => { addRepository(this.getUIContext(), 'remote') } })
            SettingsRow({ title: '导入备份配置',
              action: (): void => { this.importBackup() } })
            SettingsRow({ title: '添加本地目录', divider: false,
              action: (): void => { addRepository(this.getUIContext(), 'localDirectory') } })
          }.width('100%').backgroundColor(UiColor.container).borderRadius(12).clip(true)
        }.width('100%').enabled(!this.selectingBackup)
      }.width('100%').constraintSize({ maxWidth: 400 }).padding({ left: 24, right: 24, top: 24, bottom: 24 })
    }.width('100%').height('100%').align(Alignment.Center).scrollBar(BarState.Off)
  }
}
