import { InsightIntentEntry, InsightIntentEntryExecutor, insightIntent } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { captureTitle } from '../services/CaptureInput'

@InsightIntentEntry({
  intentName: 'CaptureInboxTitle', domain: 'Tasks', intentVersion: '1.0.0',
  displayName: '记到小清单收件箱', displayDescription: '只需一个标题，将待办事项放进小清单收件箱。',
  llmDescription: '捕捉用户说出的任务标题，打开小清单收件箱录入界面，由用户确认保存。保留原话，不提取日期、标签或优先级。',
  keywords: ['小清单', '创建任务', '记一条', '快速捕捉', '收件箱'],
  parameters: { type: 'object', properties: { title: { type: 'string', description: '需要记入收件箱的完整标题' } }, required: ['title'] },
  abilityName: 'CaptureAbility', executeMode: [insightIntent.ExecuteMode.UI_ABILITY_FOREGROUND]
})
export default class CaptureIntent extends InsightIntentEntryExecutor<string> {
  title: string = ''

  async onExecute(): Promise<insightIntent.IntentResult<string>> {
    if (!this.windowStage) return { code: 1, result: '无法打开捕捉窗口' }
    AppStorage.setOrCreate('captureRequest', { id: '', title: '', voice: false })
    AppStorage.set('captureRequest', { id: util.generateRandomUUID(), title: captureTitle(this.title), voice: false })
    return { code: 0, result: '请确认标题并保存到收件箱' }
  }
}
