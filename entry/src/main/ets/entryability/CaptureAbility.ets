import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { captureRequest } from '../services/CaptureInput'

export default class CaptureAbility extends UIAbility {

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try { this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK) }
    catch (error) { console.error('设置应用深色模式失败') }
    AppStorage.setOrCreate('captureVisible', true)
    const request = captureRequest(want)
    console.info(`捕捉窗口收到启动参数，标题长度：${request.title.length}，语音：${request.voice}`)
    AppStorage.setOrCreate('captureRequest', request)
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const request = captureRequest(want)
    console.info(`捕捉窗口收到热启动参数，标题长度：${request.title.length}，语音：${request.voice}`)
    AppStorage.setOrCreate('captureRequest', request)
  }

  onForeground(): void { AppStorage.setOrCreate('captureVisible', true) }

  onBackground(): void { AppStorage.setOrCreate('captureVisible', false) }

  async onWindowStageCreate(stage: window.WindowStage): Promise<void> {
    try {
      const mainWindow = stage.getMainWindowSync()
      await stage.loadContent('pages/Capture')
      // UIContent 创建后才允许设置透明背景。
      mainWindow.setWindowBackgroundColor('#00000000')
    } catch (error) { console.error('初始化应用窗口失败') }
  }
}
