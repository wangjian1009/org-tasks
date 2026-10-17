import { router } from '@kit.ArkUI'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { BackgroundSyncService } from '../services/BackgroundSyncService'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, coreErrorMessage } from '../services/NativeCoreService'
import { AppShell } from '../components/AppShell'
import { MessageBar, PreferenceRow, SectionHeading } from '../components/Controls'
import { UiColor } from '../ui/Theme'

@Entry
@Component
struct Settings {
  @State config: AppConfig = DEFAULT_CONFIG
  @State section: string = ''
  @State inboxFile: string = 'inbox.org'
  @State calendarName: string = 'Org Tasks'
  @State syncInterval: string = '20'
  @State saving: boolean = false
  @State loaded: boolean = false
  @State message: string = ''
  @State drawerOpen: boolean = false

  onPageShow() { this.load() }
  onBackPress(): boolean {
    if (this.saving) return true
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    if (this.section) { this.section = ''; this.message = ''; return true }
    return false
  }

  async load() {
    try {
      this.config = await AppConfigService.load(getContext(this))
      this.inboxFile = this.config.inboxFile
      this.calendarName = this.config.calendarName
      this.syncInterval = Math.max(20, this.config.syncInterval).toString()
      this.loaded = true
    } catch (e) { this.message = `读取设置失败：${coreErrorMessage(e as CoreBridgeError)}` }
  }

  async save() {
    if (this.saving || !this.loaded) return
    const interval = Number(this.syncInterval)
    if (!this.inboxFile.trim() || !this.calendarName.trim() || !Number.isInteger(interval) || interval < 20) {
      this.message = '请填写收集箱文件和日历名称，同步间隔应为至少 20 的整数'; return
    }
    const inbox = this.inboxFile.trim()
    if (!inbox.endsWith('.org') || inbox.startsWith('/') || inbox.split('/').some((part: string) => part === '..' || part.length === 0)) {
      this.message = '收集箱必须是存储库中的相对 .org 路径'; return
    }
    this.saving = true
    try {
      const current = await AppConfigService.load(getContext(this))
      await AppConfigService.save(getContext(this), { repos: current.repos, inboxFile: this.inboxFile.trim(), calendarName: this.calendarName.trim(), syncInterval: interval })
      this.message = '设置已保存'
      try { await BackgroundSyncService.configure(interval) }
      catch (e) { this.message = `设置已保存，后台调度更新失败：${coreErrorMessage(e as CoreBridgeError)}` }
    } catch (e) { this.message = `保存设置失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.saving = false }
  }

  build() {
    Column() {
      AppShell({ title: this.section || '设置', activeRoute: 'pages/Settings', drawerOpen: $drawerOpen,
        back: this.section.length > 0, busy: this.saving, backAction: () => { this.section = ''; this.message = '' },
        actionIcon: $r('app.media.ui_done'), actionLabel: this.section === '同步' || this.section === '笔记与笔记本' ? '保存设置' : '', action: (): void => { this.save() } }) {
        Column() {
          MessageBar({ message: this.message, error: this.message !== '设置已保存' })
          Scroll() {
            Column() {
              if (!this.section) {
                PreferenceRow({ title: '笔记与笔记本', detail: '新增任务的收集箱文件', icon: $r('app.media.ui_folder'), action: () => { this.section = '笔记与笔记本' } })
                PreferenceRow({ title: '同步', detail: '存储库、系统日历与后台同步', icon: $r('app.media.ui_sync'), action: () => { this.section = '同步' } })
                PreferenceRow({ title: '应用程序', detail: 'Org Tasks', icon: $r('app.media.ui_info'), action: () => { this.section = '应用程序' } })
              } else if (this.section === '同步') {
                PreferenceRow({ title: '存储库', detail: `${this.config.repos.length} 个本地或 WebDAV 存储库`, icon: $r('app.media.ui_cloud'), action: (): void => { router.pushUrl({ url: 'pages/Repositories' }) } })
                Divider().color(UiColor.outline)
                SectionHeading({ title: '系统日历' })
                Column({ space: 12 }) {
                  Text('日历名称').fontSize(14).fontColor(UiColor.secondary).width('100%')
                  TextInput({ text: this.calendarName, placeholder: 'Org Tasks' }).height(56).backgroundColor(UiColor.field).borderRadius(6)
                    .onChange((value: string) => { this.calendarName = value })
                  Text('同步中心会将具有计划或截止时间的任务写入此日历。').fontSize(13).lineHeight(21).fontColor(UiColor.secondary).width('100%')
                }.width('100%').padding({ left: 24, right: 24 })
                SectionHeading({ title: '自动同步' })
                Column({ space: 12 }) {
                  Text('间隔（分钟）').fontSize(14).fontColor(UiColor.secondary).width('100%')
                  TextInput({ text: this.syncInterval, placeholder: '20' }).type(InputType.Number).height(56).backgroundColor(UiColor.field).borderRadius(6)
                    .onChange((value: string) => { this.syncInterval = value })
                  Text('至少 20 分钟；保存后由系统后台任务调度，实际执行可能延后。').fontSize(13).lineHeight(21).fontColor(UiColor.secondary).width('100%')
                }.width('100%').padding({ left: 24, right: 24 })
                Button(this.saving ? '保存中…' : '保存设置').width('88%').height(48).backgroundColor(UiColor.primary).margin({ top: 32 })
                  .enabled(!this.saving && this.loaded).onClick((): void => { this.save() })
              } else if (this.section === '笔记与笔记本') {
                SectionHeading({ title: '收集箱' })
                Column({ space: 16 }) {
                  Text('新增任务文件').fontSize(14).fontColor(UiColor.secondary).width('100%')
                  TextInput({ text: this.inboxFile, placeholder: 'inbox.org' }).height(56).backgroundColor(UiColor.field).borderRadius(6)
                    .onChange((value: string) => { this.inboxFile = value })
                  Text('新增任务会写入所选存储库中的此文件，请使用相对 .org 路径。').fontSize(13).fontColor(UiColor.secondary).lineHeight(21).width('100%')
                  Button('保存设置').width('100%').height(48).backgroundColor(UiColor.primary).enabled(!this.saving && this.loaded).onClick((): void => { this.save() })
                }.width('100%').padding(24)
              } else {
                SectionHeading({ title: 'Org Tasks' })
                Text('浏览 Org 笔记本、按日期查看任务，并将任务同步到 HarmonyOS 系统日历。')
                  .fontSize(16).fontColor(UiColor.secondary).lineHeight(26).width('100%').padding(24)
              }
            }.width('100%').padding({ bottom: 32 }).enabled(!this.saving)
          }.width('100%').layoutWeight(1).align(Alignment.TopStart)
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
