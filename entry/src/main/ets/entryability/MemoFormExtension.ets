import { Context, Want } from '@kit.AbilityKit'
import { FormExtensionAbility, formBindingData, formInfo, formProvider } from '@kit.FormKit'
import { preferences } from '@kit.ArkData'
import { BusinessError } from '@kit.BasicServicesKit'
import { APP_CONFIG_PREFERENCES, AppConfigService } from '../services/AppConfigService'
import { fileTargetRepository, FileTargetService } from '../services/FileTargetService'
import { CoreTask, NativeCoreService } from '../services/NativeCoreService'

interface MemoFormData {
  memoCardTitle: string
  memoCardItem1: string
  memoCardItem2: string
  memoCardItem3: string
  memoCardMessage: string
}

function formData(tasks: CoreTask[], message: string = '暂无备忘'): MemoFormData {
  const values = tasks.map((task: CoreTask): string => task.heading.trim())
    .filter((title: string): boolean => title.length > 0).slice(0, 3)
  return {
    memoCardTitle: '全部备忘',
    memoCardItem1: values[0] ?? '', memoCardItem2: values[1] ?? '', memoCardItem3: values[2] ?? '', memoCardMessage: message
  }
}

export default class MemoFormExtension extends FormExtensionAbility {
  private readonly formIds: Set<string> = new Set<string>()
  private pendingRefresh: Promise<void> = Promise.resolve()

  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId = want.parameters?.[formInfo.FormParam.IDENTITY_KEY] as string | undefined
    if (formId) {
      this.formIds.add(formId)
      this.refreshForm(formId)
    }
    return formBindingData.createFormBindingData(formData([], '正在读取备忘…'))
  }

  onUpdateForm(formId: string): void {
    this.formIds.add(formId)
    this.refreshForm(formId)
  }

  onRemoveForm(formId: string): void { this.formIds.delete(formId) }

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
    let data: MemoFormData = formData([])
    try {
      await preferences.removePreferencesFromCache(this.context, APP_CONFIG_PREFERENCES)
      const config = await AppConfigService.load(this.context as Context, false)
      const repository = fileTargetRepository(config, 'memo')
      if (repository) {
        const repo = await NativeCoreService.repository([repository], repository, config.todoDefaults)
        await repo.load()
        const result = await FileTargetService.query(config, 'memo')
        data = result ? formData(result.tasks) : formData([], '备忘文件已失效，请在应用中重新选择')
      } else {
        data = formData([], '请先在应用中选择备忘文件')
      }
    } catch (error) {
      console.error('读取备忘卡片失败，错误码:', (error as BusinessError).code)
      data = formData([], '暂时无法读取备忘，点击打开应用')
    }
    if (!this.formIds.has(formId)) return
    try { await formProvider.updateForm(formId, formBindingData.createFormBindingData(data)) }
    catch (error) { console.error('更新备忘卡片失败，错误码:', (error as BusinessError).code) }
  }
}
