import { Context, Want } from '@kit.AbilityKit'
import { FormExtensionAbility, formBindingData, formInfo, formProvider } from '@kit.FormKit'
import { AppConfigService } from '../services/AppConfigService'
import { FileTargetService } from '../services/FileTargetService'
import { CoreTask } from '../services/NativeCoreService'

interface MemoFormData {
  memoCardTitle: string
  memoCardItem1: string
  memoCardItem2: string
  memoCardItem3: string
}

const EMPTY_DATA: MemoFormData = {
  memoCardTitle: '全部备忘', memoCardItem1: '', memoCardItem2: '', memoCardItem3: ''
}

function formData(tasks: CoreTask[]): MemoFormData {
  const values = tasks.map((task: CoreTask): string => task.heading.trim())
    .filter((title: string): boolean => title.length > 0).slice(0, 3)
  return {
    memoCardTitle: '全部备忘',
    memoCardItem1: values[0] ?? '', memoCardItem2: values[1] ?? '', memoCardItem3: values[2] ?? ''
  }
}

export default class MemoFormExtension extends FormExtensionAbility {
  private readonly formIds: Set<string> = new Set<string>()

  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId = want.parameters?.[formInfo.FormParam.IDENTITY_KEY] as string | undefined
    if (formId) {
      this.formIds.add(formId)
      this.refreshForm(formId)
    }
    return formBindingData.createFormBindingData(EMPTY_DATA)
  }

  onUpdateForm(formId: string): void {
    this.formIds.add(formId)
    this.refreshForm(formId)
  }

  onRemoveForm(formId: string): void { this.formIds.delete(formId) }

  private async refreshForm(formId: string): Promise<void> {
    try {
      const config = await AppConfigService.load(this.context as Context, false)
      const result = await FileTargetService.query(config, 'memo')
      if (!this.formIds.has(formId)) return
      await formProvider.updateForm(formId, formBindingData.createFormBindingData(result ? formData(result.tasks) : EMPTY_DATA))
    } catch (error) {
      if (!this.formIds.has(formId)) return
      try { await formProvider.updateForm(formId, formBindingData.createFormBindingData(EMPTY_DATA)) }
      catch (updateError) { console.error('更新备忘卡片失败', JSON.stringify(updateError)) }
    }
  }
}
