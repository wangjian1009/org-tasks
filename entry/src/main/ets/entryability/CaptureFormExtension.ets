import { Want } from '@kit.AbilityKit'
import { FormExtensionAbility, formBindingData } from '@kit.FormKit'

export default class CaptureFormExtension extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    return formBindingData.createFormBindingData({})
  }
}
