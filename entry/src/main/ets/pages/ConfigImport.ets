import { localizedText } from '../ui/LocalizedText'
import { common } from '@kit.AbilityKit'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/controls/EmptyState'
import { MessageBar } from '../components/controls/MessageBar'
import { SettingsGroup } from '../components/controls/SettingsGroup'
import { SettingsRow } from '../components/controls/SettingsRow'
import { ConfigImportPreview, ConfigTransfer, TransferRepository } from '../services/ConfigTransfer'
import { PageNavigator } from '../services/PageNavigator'
import { PageParameters } from '../services/PagePath'
import { UiColor } from '../ui/Theme'

@Entry({ useSharedStorage: true })
@Component
struct ConfigImport {
  @LocalStorageProp('configImportUri') externalUri: string = ''
  @State openedUri: string = ''
  @State drawerOpen: boolean = false
  @State busy: boolean = false
  @State applied: boolean = false
  @State message: string = ''
  @State preview: ConfigImportPreview | undefined = undefined
  private inApp: boolean = false
  private stopExternalGuard: (() => void) | undefined = undefined

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as PageParameters | undefined
    this.inApp = !this.externalUri && !!params?.configImportUri
    this.openedUri = this.externalUri || params?.configImportUri || ''
    if (this.openedUri) this.readFile()
    else this.message = localizedText($r('app.string.text_could_not_open_this_configuration_please_check'))
  }

  onPageShow(): void {
    this.stopExternalGuard?.()
    if (this.inApp) this.stopExternalGuard = PageNavigator.shared.watchExternalLeaveGuard((): boolean => !this.busy)
  }

  onPageHide(): void {
    this.stopExternalGuard?.()
    this.stopExternalGuard = undefined
  }

  aboutToDisappear(): void { this.stopExternalGuard?.() }

  onBackPress(): boolean {
    if (!this.busy) this.close()
    return true
  }

  private async close(): Promise<void> {
    if (this.inApp) {
      await PageNavigator.shared.back(this.getUIContext())
      return
    }
    try {
      await (this.getUIContext().getHostContext()! as common.UIAbilityContext).terminateSelf()
    } catch (_) { this.message = localizedText($r('app.string.text_failed_to_close_import_page_please_try')) }
  }

  private async readFile(): Promise<void> {
    if (this.busy || !this.openedUri) return
    this.busy = true
    this.message = ''
    this.preview = undefined
    try {
      let text: string
      try { text = await ConfigTransfer.readFile(this.openedUri) }
      catch (_) {
        this.message = localizedText($r('app.string.text_couldn_t_read_the_settings_file_check'))
        return
      }
      this.preview = await ConfigTransfer.preview(this.getUIContext().getHostContext()!, text)
    } catch (error) { this.message = (error as Error).message || localizedText($r('app.string.text_could_not_recognize_this_configuration')) }
    finally { this.busy = false }
  }

  private async apply(): Promise<void> {
    const preview = this.preview
    if (this.busy || !preview) return
    this.busy = true
    this.message = ''
    try {
      await ConfigTransfer.apply(this.getUIContext().getHostContext()!, preview)
      this.applied = true
      this.preview = undefined
      await this.finishImport()
    } catch (error) {
      this.preview = undefined
      this.message = (error as Error).message || localizedText($r('app.string.text_save_configuration_failed_re_prefer'))
    } finally { this.busy = false }
  }

  private async finishImport(): Promise<void> {
    if (this.inApp) {
      await this.close()
      return
    }
    try {
      const context = this.getUIContext().getHostContext()! as common.UIAbilityContext
      await context.startAbility({ bundleName: context.abilityInfo.bundleName, abilityName: 'EntryAbility' })
      await context.terminateSelf()
    } catch (_) { this.message = localizedText($r('app.string.text_configure_applied_cannot_return_org_tasks_for')) }
  }

  @Builder
  previewContent(preview: ConfigImportPreview) {
    Column() {
      SettingsGroup({ title: localizedText($r('app.string.text_notebook_shortcuts')) }) {
        SettingsRow({ title: localizedText($r('app.string.text_inbox')), value: preview.document.settings.inboxFile || localizedText($r('app.string.text_unconfigured')), disclosure: false })
        SettingsRow({ title: localizedText($r('app.string.text_someday')), value: preview.document.settings.somedayFile || localizedText($r('app.string.text_unconfigured')), disclosure: false })
        SettingsRow({ title: localizedText($r('app.string.text_notes')), value: preview.document.settings.memoFile || localizedText($r('app.string.text_unconfigured')), disclosure: false, divider: false })
      }
      SettingsGroup({ title: localizedText($r('app.string.text_repository_to_import')) }) {
        if (preview.document.settings.repos.length === 0) {
          SettingsRow({ title: localizedText($r('app.string.text_no_repository_in_file')), disclosure: false, divider: false })
        }
        ForEach(preview.document.settings.repos, (repo: TransferRepository) => {
          SettingsRow({ title: repo.name || repo.rootDirectory, value: repo.webdavEnabled ? 'WebDAV' : '',
            detail: repo.rootDirectory, disclosure: false })
        }, (repo: TransferRepository): string => repo.id)
      }
      SettingsGroup({ title: localizedText($r('app.string.text_other_configurations')) }) {
        SettingsRow({ title: localizedText($r('app.string.text_file_view')), value: preview.document.settings.fileDisplayMode === 'source' ? localizedText($r('app.string.text_source')) : localizedText($r('app.string.text_rendered')), disclosure: false })
        SettingsRow({ title: localizedText($r('app.string.text_customised_task_status')), value: preview.document.settings.coreSettings.additionStates.length + localizedText($r('app.string.text_one')),
          disclosure: false, divider: false })
      }
      if (preview.warnings.length > 0) {
        SettingsGroup({ title: localizedText($r('app.string.text_needs_processing_after_import')) }) {
          ForEach(preview.warnings, (warning: string) => {
            Text(warning).fontSize(14).fontColor(UiColor.warning).width('100%').padding(14)
          }, (warning: string): string => warning)
        }
      }
    }.width('100%')
  }

  build() {
    Column() {
      AppShell({ title: localizedText($r('app.string.text_import_configuration')), back: true, busy: this.busy, drawerOpen: $drawerOpen,
        backAction: (): void => { this.onBackPress() } }) {
        Column() {
          MessageBar({ message: this.message, error: true })
          if (this.applied) {
            EmptyState({ title: localizedText($r('app.string.text_configure_imported')), actionLabel: localizedText($r('app.string.text_back_to_org_tasks')), action: (): void => { this.finishImport() } })
          } else if (this.preview) {
            Scroll() {
              Column() {
                Text($r('app.string.text_when_applied_the_file_entry_task_status'))
                  .fontSize(14).fontColor(UiColor.secondary).width('100%').padding({ top: 16, left: 12, right: 12 })
                this.previewContent(this.preview)
              }.width('100%').padding({ left: 16, right: 16, bottom: 24 })
            }.width('100%').layoutWeight(1)
            Button($r('app.string.text_apply_configuration')).width('100%').height(48).borderRadius(12)
              .backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary)
              .enabled(!this.busy).onClick((): void => { this.apply() }).margin({ top: 8, bottom: 16 })
          } else if (this.busy) {
            EmptyState({ title: localizedText($r('app.string.text_reading_configuration')), busy: true })
          } else if (this.openedUri) {
            EmptyState({ title: localizedText($r('app.string.text_configure_cannot_temporarily_import')), actionLabel: localizedText($r('app.string.text_reread')), action: (): void => { this.readFile() } })
          }
        }.width('100%').height('100%').padding({ left: 16, right: 16 })
      }
    }.width('100%').height('100%')
  }
}
