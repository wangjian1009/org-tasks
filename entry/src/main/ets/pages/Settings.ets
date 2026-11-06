import { defaultTodoSettings } from 'liborg_tasks_harmony.so'
import { router } from '@kit.ArkUI'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { BackgroundSyncService } from '../services/BackgroundSyncService'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, coreErrorMessage, NativeCoreService } from '../services/NativeCoreService'
import { AppShell } from '../components/AppShell'
import { MessageBar, PreferenceRow, SectionHeading } from '../components/Controls'
import { UiColor, repositoryLabel } from '../ui/Theme'
import { configuredFileTarget, FileTargetKind } from '../services/FileTargetService'

interface SettingsParams { section?: string }

@Entry
@Component
struct Settings {
  @State config: AppConfig = DEFAULT_CONFIG
  @State section: string = ''
  @State calendarName: string = 'Org Tasks'
  @State syncInterval: string = '20'
  @State todoDefaults: string = ''
  @State fileDisplayMode: 'rendered' | 'source' = 'rendered'
  @State saving: boolean = false
  @State loaded: boolean = false
  @State message: string = ''
  @State drawerOpen: boolean = false
  private saveTimer: number = -1
  private saveRequested: boolean = false

  onPageShow() { this.load() }
  onBackPress(): boolean {
    if (this.saveTimer >= 0) {
      clearTimeout(this.saveTimer)
      this.saveTimer = -1
      this.save()
      return true
    }
    if (this.saving) return true
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    if (this.section) { this.section = ''; this.message = ''; return true }
    return false
  }

  async load() {
    try {
      this.config = await AppConfigService.load(getContext(this))
      if (!this.loaded) {
        const params = router.getParams() as SettingsParams | undefined
        if (params?.section) this.section = params.section
        this.todoDefaults = this.config.todoDefaults
        this.fileDisplayMode = this.config.fileDisplayMode
        this.calendarName = this.config.calendarName
        this.syncInterval = Math.max(20, this.config.syncInterval).toString()
      }
      this.loaded = true
    } catch (e) { this.message = `读取设置失败：${coreErrorMessage(e as CoreBridgeError)}` }
  }

  fileTargetDetail(kind: FileTargetKind): string {
    const target = configuredFileTarget(this.config, kind)
    if (!target.path) return '未选择'
    const repository = this.config.repos.find(repo => repo.id === target.repoId)
    if (!repository) return `需要重新选择 · ${target.path}`
    return `${repositoryLabel(repository)} / ${target.path}`
  }

  scheduleSave() {
    if (!this.loaded) return
    this.saveRequested = true
    if (this.saveTimer >= 0) clearTimeout(this.saveTimer)
    this.saveTimer = setTimeout((): void => {
      this.saveTimer = -1
      if (!this.saving) this.save()
    }, 250)
  }

  async save() {
    if (!this.loaded) return
    this.saveRequested = true
    if (this.saving) return
    this.saving = true
    try {
      while (this.saveRequested) {
        this.saveRequested = false
        const interval = Number(this.syncInterval)
        if (!this.calendarName.trim() || !Number.isInteger(interval) || interval < 20) {
          this.message = '请填写日历名称，同步间隔应为至少 20 的整数'
          break
        }
        const current = await AppConfigService.load(getContext(this))
        const todoChanged = current.todoDefaults !== this.todoDefaults
        current.calendarName = this.calendarName.trim()
        current.syncInterval = interval
        current.todoDefaults = this.todoDefaults
        current.fileDisplayMode = this.fileDisplayMode
        await AppConfigService.save(getContext(this), current)
        if (todoChanged) await NativeCoreService.workspaceFor(current.repos, this.todoDefaults)
        this.message = '设置已保存'
        try { await BackgroundSyncService.configure(interval) }
        catch (e) { this.message = `设置已保存，后台调度更新失败：${coreErrorMessage(e as CoreBridgeError)}` }
      }
    } catch (e) { this.message = `保存设置失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally {
      this.saving = false
      if (this.saveRequested) this.save()
    }
  }

  build() {
    Column() {
      AppShell({ title: this.section || '设置', activeRoute: 'pages/Settings', drawerOpen: $drawerOpen,
        back: false, busy: this.saving, titleIcon: $r('app.media.nav_settings') }) {
        Column() {
          MessageBar({ message: this.message, error: this.message !== '设置已保存' })
          Scroll() {
            Column() {
              if (!this.section) {
                PreferenceRow({ title: '笔记与笔记本', icon: $r('app.media.ui_folder'), action: () => { this.section = '笔记与笔记本' } })
                PreferenceRow({ title: '应用程序', icon: $r('app.media.ui_info'), action: () => { this.section = '应用程序' } })
              } else if (this.section === '笔记与笔记本') {
                SectionHeading({ title: '文件展示' })
                PreferenceRow({ title: '文件展示方式', detail: this.fileDisplayMode === 'source' ? '原文' : '渲染（默认）', icon: $r('app.media.ui_body'),
                  action: (): void => {
                    this.getUIContext().showActionSheet({ title: '文件展示方式', message: '选择打开文件时的展示方式，修改后立即保存。', sheets: [
                      { title: '渲染（默认）', action: (): void => { this.fileDisplayMode = 'rendered'; this.scheduleSave() } },
                      { title: '原文', action: (): void => { this.fileDisplayMode = 'source'; this.scheduleSave() } }
                    ] })
                  } })
                SectionHeading({ title: '默认 TODO 流程' })
                Column({ space: 12 }) {
                  TextArea({ text: this.todoDefaults, placeholder: '从 Rust 获取的默认设置，可按 Org 声明编辑' }).width('100%').height(180)
                    .fontFamily('monospace').backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary).borderRadius(6)
                    .onChange((value: string) => { this.todoDefaults = value; this.scheduleSave() })
                  Text('使用 TODO、SEQ_TODO 或 TYP_TODO 声明，每行一套流程；| 后为完成状态。文件内声明会整体覆盖此默认值。留空表示默认不识别 TODO 状态。')
                    .fontSize(13).fontColor(UiColor.secondary).lineHeight(21).width('100%')
                  Button('恢复默认 TODO 设置').fontSize(14).backgroundColor(UiColor.selected).fontColor(UiColor.onSelected)
                    .onClick(async (): Promise<void> => {
                      try { this.todoDefaults = await defaultTodoSettings(); this.scheduleSave() }
                      catch (e) { this.message = `读取默认设置失败：${coreErrorMessage(e as CoreBridgeError)}` }
                    })
                }.width('100%').padding({ left: 24, right: 24 })
                SectionHeading({ title: '文件入口' })
                Column({ space: 16 }) {
                  PreferenceRow({ title: '收件箱文件', detail: this.fileTargetDetail('inbox'), icon: $r('app.media.nav_inbox'), action: (): void => { router.pushUrl({ url: 'pages/FileTargetPicker', params: { kind: 'inbox' } }) } })
                  Text('收件箱展示所选仓库中的文件；未配置时点击入口提示设置。').fontSize(13).fontColor(UiColor.secondary).lineHeight(21).width('100%')
                  PreferenceRow({ title: '某天文件', detail: this.fileTargetDetail('someday'), icon: $r('app.media.nav_someday'), action: (): void => { router.pushUrl({ url: 'pages/FileTargetPicker', params: { kind: 'someday' } }) } })
                  Text('“某天”展示所选文件中的未完成任务。').fontSize(13).fontColor(UiColor.secondary).lineHeight(21).width('100%')
                  PreferenceRow({ title: '备忘文件', detail: this.fileTargetDetail('memo'), icon: $r('app.media.nav_memo'), action: (): void => { router.pushUrl({ url: 'pages/FileTargetPicker', params: { kind: 'memo' } }) } })
                  Text('“备忘”展示所选文件中的全部标题记录。').fontSize(13).fontColor(UiColor.secondary).lineHeight(21).width('100%')
                }.width('100%').padding(24)
              } else {
                SectionHeading({ title: '小清单' })
                Text('浏览 Org 笔记本、按日期查看任务，并将任务同步到 HarmonyOS 系统日历。')
                  .fontSize(16).fontColor(UiColor.secondary).lineHeight(26).width('100%').padding(24)
              }
            }.width('100%').padding({ bottom: 32 }).enabled(this.loaded)
          }.width('100%').layoutWeight(1).align(Alignment.TopStart)
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
