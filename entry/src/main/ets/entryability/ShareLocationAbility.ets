import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { ShareLocationRequest } from '../services/SharedLocationService'

export default class ShareLocationAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK)
    const request: ShareLocationRequest = {
      title: typeof want.parameters?.title === 'string' ? want.parameters.title : '',
      url: typeof want.parameters?.url === 'string' ? want.parameters.url : ''
    }
    AppStorage.setOrCreate('shareLocationRequest', request)
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const request: ShareLocationRequest = {
      title: typeof want.parameters?.title === 'string' ? want.parameters.title : '',
      url: typeof want.parameters?.url === 'string' ? want.parameters.url : ''
    }
    AppStorage.setOrCreate('shareLocationRequest', request)
  }

  async onWindowStageCreate(stage: window.WindowStage): Promise<void> {
    await stage.loadContent('pages/ShareLocation')
    stage.getMainWindowSync().setWindowBackgroundColor('#2D2C2B')
  }
}
