import { InsightIntentEntry, InsightIntentEntryExecutor, insightIntent } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { CaptureRequest, captureTitle } from '../services/CaptureInput'

@InsightIntentEntry({
  intentName: 'CaptureInboxTitle', domain: 'Tasks', intentVersion: '1.0.0',
  displayName: '记到小清单', displayDescription: '只需一个标题，保存到小清单。',
  llmDescription: '捕捉用户说出的标题，打开小清单确认界面，由用户确认保存。保留原话，不提取日期、标签或优先级。',
  keywords: ['小清单', '创建任务', '记一条', '快速捕捉'],
  parameters: {
    '$schema': 'http://json-schema.org/draft-07/schema#', type: 'object', title: 'Capture title schema',
    properties: { title: { type: 'string', description: '需要记入小清单的完整标题', minLength: 1 } },
    required: ['title'], additionalProperties: false
  },
  result: {
    '$schema': 'http://json-schema.org/draft-07/schema#', type: 'object',
    properties: { code: { type: 'number' }, result: { type: 'string' } },
    required: ['code', 'result'], additionalProperties: false
  },
  // 前台意图必须绑定实际显示捕捉页面的 Ability，由 windowStage 直接加载页面。
  abilityName: 'CaptureAbility', executeMode: [insightIntent.ExecuteMode.UI_ABILITY_FOREGROUND]
})
export default class CaptureIntent extends InsightIntentEntryExecutor<string> {
  title: string = ''

  async onExecute(): Promise<insightIntent.IntentResult<string>> {
    const title = captureTitle(this.title)
    try {
      // 官方前台意图流程在绑定 Ability 的 onWindowStageCreate 后调用 onExecute。
      // 在同一 Ability 的 AppStorage 中写入请求，再由其 WindowStage 显示捕捉页面。
      const request: CaptureRequest = { id: util.generateRandomUUID(), title, voice: false }
      AppStorage.setOrCreate('captureVisible', true)
      AppStorage.setOrCreate('captureRequest', request)
      if (!this.windowStage) return { code: 1, result: '无法打开小清单捕捉窗口，请重试' }
      await this.windowStage.loadContent('pages/Capture')
      console.info(`小艺捕捉意图已打开确认窗口，标题长度：${title.length}`)
      return { code: 0, result: '请确认标题并保存到小清单' }
    } catch (error) {
      console.error(`小艺捕捉意图启动透明窗口失败：${JSON.stringify(error)}`)
      return { code: 1, result: '无法打开小清单捕捉窗口，请重试' }
    }
  }
}
