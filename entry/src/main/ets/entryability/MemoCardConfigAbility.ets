import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { memoCardFormId } from '../services/MemoCardService'
import { UiColor } from '../ui/Theme'

interface MemoCardConfigStorage { memoCardFormId: string }

export default class MemoCardConfigAbility extends UIAbility {
  private formId: string = ''

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.formId = memoCardFormId(want)
    try { this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK) }
    catch (_) { console.error('设置卡片编辑页深色模式失败') }
  }

  async onWindowStageCreate(stage: window.WindowStage): Promise<void> {
    try {
      const storage: MemoCardConfigStorage = { memoCardFormId: this.formId }
      await stage.loadContent('pages/MemoCardConfig', new LocalStorage(storage))
      const mainWindow = stage.getMainWindowSync()
      mainWindow.setWindowBackgroundColor(UiColor.surface)
      await mainWindow.setWindowSystemBarProperties({ statusBarColor: UiColor.surface,
        navigationBarColor: UiColor.surface, statusBarContentColor: UiColor.text, navigationBarContentColor: UiColor.text })
    } catch (_) { console.error('加载卡片编辑页失败') }
  }
}
