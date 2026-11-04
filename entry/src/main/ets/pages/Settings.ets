import { defaultTodoSettings } from 'liborg_tasks_harmony.so'
import { router } from '@kit.ArkUI'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { BackgroundSyncService } from '../services/BackgroundSyncService'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, coreErrorMessage, NativeCoreService } from '../services/NativeCoreService'
import { AppShell } from '../components/AppShell'
import { MessageBar, PreferenceRow, SectionHeading } from '../components/Controls'
import { UiColor } from '../ui/Theme'

interface SettingsParams { section?: string }

@Entry
@Component
struct Settings {
  @State config: AppConfig = DEFAULT_CONFIG
  @State section: string = ''
  @State inboxFile: string = ''
  @State somedayFile: string = ''
  @State memoFile: string = ''
  @State calendarName: string = 'Org Tasks'
  @State syncInterval: string = '20'
  @State todoDefaults: string = ''
  @State fileDisplayMode: 'rendered' | 'source' = 'rendered'
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
      this.somedayFile = this.config.somedayFile
      this.memoFile = this.config.memoFile
      const params = router.getParams() as SettingsParams | undefined
      if (!this.loaded && params?.section) this.section = params.section
      this.todoDefaults = this.config.todoDefaults
      this.fileDisplayMode = this.config.fileDisplayMode
      this.calendarName = this.config.calendarName
      this.syncInterval = Math.max(20, this.config.syncInterval).toString()
      this.loaded = true
    } catch (e) { this.message = `读取设置失败：${coreErrorMessage(e as CoreBridgeError)}` }
  }

  async save() {
    if (this.saving || !this.loaded) return
    const interval = Number(this.syncInterval)
    if (!this.calendarName.trim() || !Number.isInteger(interval) || interval < 20) {
      this.message = '请填写日历名称，同步间隔应为至少 20 的整数'; return
    }
    this.saving = true
    try {
      const current = await AppConfigService.load(getContext(this))
      await AppConfigService.save(getContext(this), { repos: current.repos, inboxFile: this.section === '笔记与笔记本' ? this.inboxFile.trim() : current.inboxFile, somedayFile: this.section === '笔记与笔记本' ? this.somedayFile.trim() : current.somedayFile, memoFile: this.section === '笔记与笔记本' ? this.memoFile.trim() : current.memoFile, calendarName: this.calendarName.trim(), syncInterval: interval, todoDefaults: this.section === '笔记与笔记本' ? this.todoDefaults : current.todoDefaults, fileDisplayMode: this.section === '笔记与笔记本' ? this.fileDisplayMode : current.fileDisplayMode })
      await NativeCoreService.workspaceFor(current.repos, this.section === '笔记与笔记本' ? this.todoDefaults : current.todoDefaults)
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
        titleIcon: $r('app.media.nav_settings'),
        actionIcon: $r('app.media.ui_done'), actionLabel: this.section === '笔记与笔记本' ? '保存设置' : '', action: (): void => { this.save() } }) {
        Column() {
          MessageBar({ message: this.message, error: this.message !== '设置已保存' })
          Scroll() {
            Column() {
              if (!this.section) {
                PreferenceRow({ title: '笔记与笔记本', detail: '收件箱、某天、备忘文件与默认 TODO 流程', icon: $r('app.media.ui_folder'), action: () => { this.section = '笔记与笔记本' } })
                PreferenceRow({ title: '应用程序', detail: 'Org Tasks', icon: $r('app.media.ui_info'), action: () => { this.section = '应用程序' } })
              } else if (this.section === '笔记与笔记本') {
                SectionHeading({ title: '文件展示' })
                PreferenceRow({ title: '文件展示方式', detail: this.fileDisplayMode === 'source' ? '原文' : '渲染（默认）', icon: $r('app.media.ui_body'),
                  action: (): void => {
                    this.getUIContext().showActionSheet({ title: '文件展示方式', message: '选择打开文件时的展示方式，保存后生效。', sheets: [
                      { title: '渲染（默认）', action: (): void => { this.fileDisplayMode = 'rendered' } },
                      { title: '原文', action: (): void => { this.fileDisplayMode = 'source' } }
                    ] })
                  } })
                SectionHeading({ title: '默认 TODO 流程' })
                Column({ space: 12 }) {
                  TextArea({ text: this.todoDefaults, placeholder: '从 Rust 获取的默认设置，可按 Org 声明编辑' }).width('100%').height(180)
                    .fontFamily('monospace').backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary).borderRadius(6)
                    .onChange((value: string) => { this.todoDefaults = value })
                  Text('使用 TODO、SEQ_TODO 或 TYP_TODO 声明，每行一套流程；| 后为完成状态。文件内声明会整体覆盖此默认值。留空表示默认不识别 TODO 状态。')
                    .fontSize(13).fontColor(UiColor.secondary).lineHeight(21).width('100%')
                  Button('恢复默认 TODO 设置').fontSize(14).backgroundColor(UiColor.selected).fontColor(UiColor.onSelected)
                    .onClick(async (): Promise<void> => {
                      try { this.todoDefaults = await defaultTodoSettings() }
                      catch (e) { this.message = `读取默认设置失败：${coreErrorMessage(e as CoreBridgeError)}` }
                    })
                }.width('100%').padding({ left: 24, right: 24 })
                SectionHeading({ title: '文件入口' })
                Column({ space: 16 }) {
                  Text('收件箱文件').fontSize(14).fontColor(UiColor.secondary).width('100%')
                  TextInput({ text: this.inboxFile, placeholder: 'inbox.org' }).height(56).backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary).borderRadius(6)
                    .onChange((value: string) => { this.inboxFile = value })
                  Text('新增任务写入此文件；留空时收件箱入口提示前往配置。使用相对 .org 路径。').fontSize(13).fontColor(UiColor.secondary).lineHeight(21).width('100%')
                  Text('某天文件').fontSize(14).fontColor(UiColor.secondary).width('100%')
                  TextInput({ text: this.somedayFile, placeholder: '例如 someday.org，可留空' }).height(56).backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary).borderRadius(6)
                    .onChange((value: string) => { this.somedayFile = value })
                  Text('“某天”展示此文件中的未完成任务；未配置时点击入口会提示设置。')
                    .fontSize(13).fontColor(UiColor.secondary).lineHeight(21).width('100%')
                  Text('备忘文件').fontSize(14).fontColor(UiColor.secondary).width('100%')
                  TextInput({ text: this.memoFile, placeholder: '例如 memo.org，可留空' }).height(56)
                    .backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary).borderRadius(6)
                    .onChange((value: string) => { this.memoFile = value })
                  Text('“备忘”展示此文件中的全部标题记录，包含无任务状态和已完成记录；未配置时点击入口会提示设置。')
                    .fontSize(13).fontColor(UiColor.secondary).lineHeight(21).width('100%')
                  Button('保存设置').width('100%').height(48).backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary).enabled(!this.saving && this.loaded).onClick((): void => { this.save() })
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
