import { localizedText } from '../../ui/LocalizedText'
import { UIContext } from '@kit.ArkUI'
import { UiColor } from '../../ui/Theme'

export interface DangerousConfirmationOptions {
  title: string
  message: string
  confirmLabel: string
  onConfirm: () => void
  cancelLabel?: string
  onCancel?: () => void
}

export function showDangerousConfirmation(context: UIContext, options: DangerousConfirmationOptions): void {
  let resolved = false
  const finish = (confirmed: boolean): void => {
    if (resolved) return
    resolved = true
    if (confirmed) options.onConfirm()
    else options.onCancel?.()
  }
  context.showAlertDialog({
    title: options.title,
    message: options.message,
    autoCancel: true,
    cancel: (): void => { finish(false) },
    primaryButton: { value: options.cancelLabel ?? localizedText($r('app.string.text_cancel')), defaultFocus: true, action: (): void => { finish(false) } },
    secondaryButton: { value: options.confirmLabel, fontColor: UiColor.error, action: (): void => { finish(true) } }
  })
}
