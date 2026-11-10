import { Context, Want } from '@kit.AbilityKit'
import { FormExtensionAbility, formBindingData, formInfo, formProvider } from '@kit.FormKit'
import { preferences } from '@kit.ArkData'
import { BusinessError } from '@kit.BasicServicesKit'
import { APP_CONFIG_PREFERENCES } from '../services/AppConfigService'
import { MemoCardData, memoCardData, MemoCardService } from '../services/MemoCardService'

export default class MemoFormExtension extends FormExtensionAbility {
  private readonly formIds: Set<string> = new Set<string>()
  private pendingRefresh: Promise<void> = Promise.resolve()

  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId = want.parameters?.[formInfo.FormParam.IDENTITY_KEY] as string | undefined
    if (formId) {
      this.formIds.add(formId)
      this.refreshForm(formId)
    }
    return formBindingData.createFormBindingData(memoCardData([], '', '正在读取备忘…'))
  }

  onUpdateForm(formId: string): void {
    this.formIds.add(formId)
    this.refreshForm(formId)
  }

  onRemoveForm(formId: string): void {
    this.formIds.delete(formId)
    MemoCardService.remove(this.context as Context, formId)
      .catch((): void => { console.error('清理备忘卡片设置失败') })
  }

  onCastToNormalForm(formId: string): void { this.onUpdateForm(formId) }

  onChangeFormVisibility(newStatus: Record<string, number>): void {
    for (const formId of Object.keys(newStatus)) {
      if (newStatus[formId] === formInfo.VisibilityType.FORM_VISIBLE) this.onUpdateForm(formId)
    }
  }

  private refreshForm(formId: string): void {
    // 扩展进程独立缓存配置与 Core 快照；串行刷新，防止旧请求覆盖新结果。
    this.pendingRefresh = this.pendingRefresh.then((): Promise<void> => this.updateForm(formId))
  }

  private async updateForm(formId: string): Promise<void> {
    if (!this.formIds.has(formId)) return
    let tag = ''
    let data: MemoCardData = memoCardData()
    try {
      await preferences.removePreferencesFromCache(this.context, APP_CONFIG_PREFERENCES)
      tag = await MemoCardService.loadTag(this.context as Context, formId)
      data = (await MemoCardService.snapshot(this.context as Context, tag)).data
    } catch (error) {
      console.error('读取备忘卡片失败，错误码:', (error as BusinessError).code)
      data = memoCardData([], tag, '暂时无法读取备忘，点击打开应用')
    }
    if (!this.formIds.has(formId)) return
    try { await formProvider.updateForm(formId, formBindingData.createFormBindingData(data)) }
    catch (error) { console.error('更新备忘卡片失败，错误码:', (error as BusinessError).code) }
  }
}
