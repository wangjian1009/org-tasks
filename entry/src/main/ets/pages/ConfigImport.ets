import { common } from '@kit.AbilityKit'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/controls/EmptyState'
import { MessageBar } from '../components/controls/MessageBar'
import { SettingsGroup } from '../components/controls/SettingsGroup'
import { SettingsRow } from '../components/controls/SettingsRow'
import { ConfigImportPreview, ConfigTransfer, TransferRepository } from '../services/ConfigTransfer'
import { UiColor } from '../ui/Theme'

@Entry({ useSharedStorage: true })
@Component
struct ConfigImport {
  @LocalStorageProp('configImportUri') openedUri: string = ''
  @State drawerOpen: boolean = false
  @State busy: boolean = false
  @State applied: boolean = false
  @State message: string = ''
  @State preview: ConfigImportPreview | undefined = undefined
  private text: string = ''

  aboutToAppear(): void {
    if (this.openedUri) this.readFile(this.openedUri)
    else this.message = '无法打开此配置，请检查文件后重新打开'
  }

  onBackPress(): boolean {
    if (!this.busy) this.close()
    return true
  }

  private async close(): Promise<void> {
    try {
      await (this.getUIContext().getHostContext()! as common.UIAbilityContext).terminateSelf()
    } catch (_) { this.message = '关闭导入页面失败，请重试' }
  }

  private async readFile(uri: string): Promise<void> {
    this.busy = true
    this.message = ''
    this.preview = undefined
    this.text = ''
    try { await this.prepare(await ConfigTransfer.readFile(uri)) }
    catch (_) { this.message = '无法读取配置文件，请检查文件是否仍可访问' }
    finally { this.busy = false }
  }

  private async prepare(text: string): Promise<void> {
    this.text = text
    this.busy = true
    this.message = ''
    this.preview = undefined
    try {
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
      this.text = ''
      await this.finishImport()
    } catch (error) {
      this.preview = undefined
      this.message = (error as Error).message || '保存配置失败，请重新预览'
    } finally { this.busy = false }
  }

  private async finishImport(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext()! as common.UIAbilityContext
      await context.startAbility({ bundleName: context.abilityInfo.bundleName, abilityName: 'EntryAbility' })
      await context.terminateSelf()
    } catch (_) { this.message = '配置已应用，暂时无法返回小清单' }
  }

  private retry(): void {
    if (this.text) this.prepare(this.text)
    else if (this.openedUri) this.readFile(this.openedUri)
  }

  @Builder
  previewContent(preview: ConfigImportPreview) {
    Column() {
      SettingsGroup({ title: '文件入口' }) {
        SettingsRow({ title: '收件箱', value: preview.document.settings.inboxFile || '未配置' })
        SettingsRow({ title: '某天', value: preview.document.settings.somedayFile || '未配置' })
        SettingsRow({ title: '备忘', value: preview.document.settings.memoFile || '未配置', divider: false })
      }
      SettingsGroup({ title: '将导入的存储库' }) {
        if (preview.document.settings.repos.length === 0) {
          SettingsRow({ title: '文件中没有存储库', divider: false })
        }
        ForEach(preview.document.settings.repos, (repo: TransferRepository) => {
          SettingsRow({ title: repo.name || repo.rootDirectory, value: repo.webdavEnabled ? 'WebDAV' : '',
            detail: repo.rootDirectory })
        }, (repo: TransferRepository): string => repo.id)
      }
      SettingsGroup({ title: '其他配置' }) {
        SettingsRow({ title: '文件展示方式', value: preview.document.settings.fileDisplayMode === 'source' ? '原文' : '渲染' })
        SettingsRow({ title: '自定义任务状态', value: preview.document.settings.coreSettings.additionStates.length + ' 个', divider: false })
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
            Button('应用配置').width('100%').height(48).backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary)
              .enabled(!this.busy).onClick((): void => { this.apply() }).margin({ top: 8, bottom: 16 })
          } else if (this.busy) {
            EmptyState({ title: '正在读取配置', busy: true })
          } else if (this.text || this.openedUri) {
            EmptyState({ title: '配置暂时无法导入', actionLabel: '重新读取', action: (): void => { this.retry() } })
          }
        }.width('100%').height('100%').padding({ left: 16, right: 16 })
      }
    }.width('100%').height('100%')
  }
}
