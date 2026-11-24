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
    else this.message = '无法打开此配置，请检查文件后重新打开'
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
    } catch (_) { this.message = '关闭导入页面失败，请重试' }
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
        this.message = '无法读取配置文件，请检查文件是否仍可访问'
        return
      }
      this.preview = await ConfigTransfer.preview(this.getUIContext().getHostContext()!, text)
    } catch (error) { this.message = (error as Error).message || '无法识别该配置' }
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
      this.message = (error as Error).message || '保存配置失败，请重新预览'
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
    } catch (_) { this.message = '配置已应用，暂时无法返回小清单' }
  }

  @Builder
  previewContent(preview: ConfigImportPreview) {
    Column() {
      SettingsGroup({ title: '文件入口' }) {
        SettingsRow({ title: '收件箱', value: preview.document.settings.inboxFile || '未配置', disclosure: false })
        SettingsRow({ title: '某天', value: preview.document.settings.somedayFile || '未配置', disclosure: false })
        SettingsRow({ title: '备忘', value: preview.document.settings.memoFile || '未配置', disclosure: false, divider: false })
      }
      SettingsGroup({ title: '将导入的存储库' }) {
        if (preview.document.settings.repos.length === 0) {
          SettingsRow({ title: '文件中没有存储库', disclosure: false, divider: false })
        }
        ForEach(preview.document.settings.repos, (repo: TransferRepository) => {
          SettingsRow({ title: repo.name || repo.rootDirectory, value: repo.webdavEnabled ? 'WebDAV' : '',
            detail: repo.rootDirectory, disclosure: false })
        }, (repo: TransferRepository): string => repo.id)
      }
      SettingsGroup({ title: '其他配置' }) {
        SettingsRow({ title: '文件展示方式', value: preview.document.settings.fileDisplayMode === 'source' ? '原文' : '渲染', disclosure: false })
        SettingsRow({ title: '自定义任务状态', value: preview.document.settings.coreSettings.additionStates.length + ' 个',
          disclosure: false, divider: false })
      }
      if (preview.warnings.length > 0) {
        SettingsGroup({ title: '导入后需要处理' }) {
          ForEach(preview.warnings, (warning: string) => {
            Text(warning).fontSize(14).fontColor(UiColor.warning).width('100%').padding(14)
          }, (warning: string): string => warning)
        }
      }
    }.width('100%')
  }

  build() {
    Column() {
      AppShell({ title: '导入配置', back: true, busy: this.busy, drawerOpen: $drawerOpen,
        backAction: (): void => { this.onBackPress() } }) {
        Column() {
          MessageBar({ message: this.message, error: true })
          if (this.applied) {
            EmptyState({ title: '配置已导入', actionLabel: '返回小清单', action: (): void => { this.finishImport() } })
          } else if (this.preview) {
            Scroll() {
              Column() {
                Text('应用后会更新文件入口、任务状态和展示方式，并按本地目录更新或添加存储库。')
                  .fontSize(14).fontColor(UiColor.secondary).width('100%').padding({ top: 16, left: 12, right: 12 })
                this.previewContent(this.preview)
              }.width('100%').padding({ left: 16, right: 16, bottom: 24 })
            }.width('100%').layoutWeight(1)
            Button('应用配置').width('100%').height(48).borderRadius(12)
              .backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary)
              .enabled(!this.busy).onClick((): void => { this.apply() }).margin({ top: 8, bottom: 16 })
          } else if (this.busy) {
            EmptyState({ title: '正在读取配置', busy: true })
          } else if (this.openedUri) {
            EmptyState({ title: '配置暂时无法导入', actionLabel: '重新读取', action: (): void => { this.readFile() } })
          }
        }.width('100%').height('100%').padding({ left: 16, right: 16 })
      }
    }.width('100%').height('100%')
  }
}
