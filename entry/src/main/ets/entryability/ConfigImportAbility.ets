import { UIAbility, Want } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { fileUri } from '@kit.CoreFileKit'
import { CONFIG_FILE_EXTENSION } from '../services/ConfigTransfer'

export default class ConfigImportAbility extends UIAbility {
  private storage: LocalStorage = new LocalStorage()

  onCreate(want: Want): void {
    if (want.action === 'ohos.want.action.viewData' && want.uri?.startsWith('file://')) {
      try {
        const file = new fileUri.FileUri(want.uri)
        if (file.host && file.host !== this.context.abilityInfo.bundleName &&
          file.name.toLowerCase().endsWith(CONFIG_FILE_EXTENSION)) {
          this.storage.setOrCreate('configImportUri', want.uri)
        }
      } catch (_) { /* 导入页显示无效入口。 */ }
    }
  }

  async onWindowStageCreate(stage: window.WindowStage): Promise<void> {
    try { await stage.loadContent('pages/ConfigImport', this.storage) }
    catch (_) {
      try { await this.context.terminateSelf() }
      catch (_) { console.error('关闭配置导入窗口失败') }
    }
  }
}
