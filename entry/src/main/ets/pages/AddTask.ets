// 新增任务页面
// 填写任务信息，写入 inbox.org

import { router } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { EmptyState, IconButton, MessageBar } from '../components/Controls'
import { dateLabel, localDate, repositoryLabel, UiColor } from '../ui/Theme'

import { AppConfig, DEFAULT_CONFIG, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
import { FileTargetService } from '../services/FileTargetService'
import { CoreBridgeError, CoreNewTask, NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'

interface EditableField {
  icon: Resource
  label: string
  value: string
  select: () => void
  clear: () => void
}

@Entry
@Component
struct AddTask {
  @State heading: string = ''
  @State scheduled: string = ''
  @State deadline: string = ''
  @State tags: string = ''
  @State priority: string = ''
  @State initialState: string = ''
  @State todoLoading: boolean = false
  private todoRequest: number = 0
  @State saving: boolean = false
  @State selectedRepoId: string = ''
  @State loading: boolean = true
  @State saved: boolean = false
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State metadataExpanded: boolean = true
  @State config: AppConfig = DEFAULT_CONFIG

  onPageShow() { if (!this.saving && !this.saved) this.loadConfig() }

  async loadConfig() {
    try {
      const context = getContext(this)
      this.config = await AppConfigService.load(context)
      this.selectedRepoId = this.config.inboxRepoId
      await this.loadInitialState()
    } catch (e) {
      this.message = `加载配置失败: ${coreErrorMessage(e as CoreBridgeError)}`
    } finally {
      this.loading = false
    }
  }

  async loadInitialState() {
    const request = ++this.todoRequest
    this.todoLoading = true
    this.initialState = ''
    this.message = ''
    try {
      const target = await FileTargetService.resolve(this.config, 'inbox')
      if (!target) { this.message = '收件箱文件未选择或已失效，请在设置中重新选择'; return }
      const file = await target.repo.file(target.path)
      const metadata = file.todo
      if (request !== this.todoRequest) return
      this.initialState = metadata.initialState || ''
      if (!this.initialState) this.message = '目标文件没有可用的未完成状态，请检查 TODO 设置'
    } catch (e) {
      if (request === this.todoRequest) this.message = `读取 TODO 设置失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally { if (request === this.todoRequest) this.todoLoading = false }
  }

  async saveTask() {
    if (this.saving || this.saved || this.loading || this.todoLoading) return
    if (!this.initialState) { this.message = '目标文件没有可用的未完成状态，请检查 TODO 设置'; return }
    if (!this.heading.trim()) {
      this.message = '请输入任务标题'
      return
    }

    const repository = this.config.repos.find((item: RepoConfig) => item.id === this.selectedRepoId)
    if (!repository) {
      this.message = '请先添加并选择仓库'
      return
    }

    this.saving = true
    this.message = ''

    const task: CoreNewTask = {
      heading: this.heading.trim(),
      scheduled: this.scheduled.trim(),
      deadline: this.deadline.trim(),
      tags: this.tags.split(/[,，\s]+/).filter((tag: string) => tag.length > 0),
      priority: this.priority
    }
    try {
      const target = await FileTargetService.resolve(this.config, 'inbox')
      if (!target) throw new Error('收件箱文件未选择或已失效，请在设置中重新选择')
      await target.repo.createTask(target.path, task, target.repository.webdavEnabled)
      this.saved = true
      this.message = repository.webdavEnabled ? '任务已保存到本地，将在后续同步时上传' : '任务已保存到本地'
    } catch (e) {
      this.message = `保存失败: ${coreErrorMessage(e as CoreBridgeError)}`
    } finally {
      this.saving = false
    }
  }

  onBackPress(): boolean { return this.saving }

  choosePriority() {
    this.getUIContext().showActionSheet({ title: '优先级', message: '', sheets: [
      { title: 'A · 高', action: () => { this.priority = 'A' } },
      { title: 'B · 中', action: () => { this.priority = 'B' } },
      { title: 'C · 低', action: () => { this.priority = 'C' } },
      { title: '清除', action: () => { this.priority = '' } }
    ] })
  }

  chooseDate(deadline: boolean) {
    const value = deadline ? this.deadline : this.scheduled
    this.getUIContext().showDatePickerDialog({ selected: value ? new Date(`${value}T12:00:00`) : new Date(),
      onAccept: (result: DatePickerResult) => {
        if (result.year !== undefined && result.month !== undefined && result.day !== undefined) {
          const date = localDate(new Date(result.year, result.month, result.day, 12))
          if (deadline) this.deadline = date; else this.scheduled = date
        }
      } })
  }

  @Builder
  field($$: EditableField) {
    Row({ space: 24 }) {
      Image($$.icon).width(24).height(24)
      Column({ space: 4 }) {
        Text($$.label).fontSize(12).fontColor(UiColor.secondary).width('100%')
        Text($$.value ? ($$.label === '优先级' ? `[#${$$.value}]` : dateLabel($$.value)) : '未设置').fontSize(16).fontColor($$.value ? UiColor.text : UiColor.secondary).width('100%')
      }.layoutWeight(1).onClick(() => $$.select())
      if ($$.value) { IconButton({ icon: $r('app.media.ui_close'), label: `清除${$$.label}`, action: $$.clear }) }
    }.width('100%').constraintSize({ minHeight: 64 }).padding({ left: 16, right: 4, top: 8, bottom: 8 })
  }

  build() {
    Column() {
      AppShell({ title: '新增任务', titleIcon: $r('app.media.ui_add'), back: true, drawerOpen: $drawerOpen, busy: this.saving,
        actionIcon: $r('app.media.ui_done'), actionLabel: this.saved ? '' : '保存任务', action: (): void => { this.saveTask() } }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在加载存储库', busy: true })
          } else if (this.saved) {
            EmptyState({ title: '任务已保存', detail: this.message, actionLabel: '返回', action: (): void => { router.back() } })
          } else if (this.config.repos.length === 0) {
            EmptyState({ title: '先添加一个存储库', detail: '选择本地 Org 文件目录，或配置 WebDAV 存储库。', actionLabel: '添加存储库',
              action: (): void => { router.pushUrl({ url: 'pages/Files' }) } })
          } else {
            MessageBar({ message: this.message, error: true })
            Scroll() {
              Column() {
                Row({ space: 16 }) {
                  Image($r('app.media.ui_folder')).width(24).height(24)
                  Text(`${repositoryLabel(this.config.repos.find((repo: RepoConfig) => repo.id === this.selectedRepoId))} / ${this.config.inboxFile}`)
                    .fontSize(14).fontColor(UiColor.primary).layoutWeight(1).maxLines(2)
                  Image($r('app.media.ui_down')).width(20).height(20)
                }.width('100%').padding(16)
                TextInput({ placeholder: '任务标题', text: this.heading }).fontSize(22).height(72).borderRadius(0)
                  .backgroundColor(Color.Transparent).fontColor(UiColor.text).placeholderColor(UiColor.secondary).onChange((value: string) => { this.heading = value })
                Divider().color(UiColor.outline)
                Row({ space: 24 }) {
                  Image($r('app.media.ui_info')).width(24).height(24)
                  Text('元数据').fontSize(14).fontColor(UiColor.secondary).layoutWeight(1)
                  Image(this.metadataExpanded ? $r('app.media.ui_up') : $r('app.media.ui_down')).width(24).height(24)
                }.width('100%').height(56).padding({ left: 16, right: 16 }).onClick(() => { this.metadataExpanded = !this.metadataExpanded })
                if (this.metadataExpanded) {
                  Row({ space: 24 }) {
                    Image($r('app.media.ui_tags')).width(24).height(24)
                    TextInput({ placeholder: '标签，用空格或逗号分隔', text: this.tags }).layoutWeight(1).height(56)
                      .backgroundColor(Color.Transparent).fontColor(UiColor.text).placeholderColor(UiColor.secondary).onChange((value: string) => { this.tags = value })
                  }.width('100%').padding({ left: 16, right: 16 })
                  Row({ space: 24 }) {
                    Image($r('app.media.ui_state')).width(24).height(24)
                    Text(this.todoLoading ? '读取中…' : this.initialState || '无可用状态').fontSize(16).fontColor(UiColor.error)
                    Text('新任务状态').fontSize(12).fontColor(UiColor.secondary)
                  }.width('100%').height(64).padding({ left: 16, right: 16 })
                  this.field({ icon: $r('app.media.ui_priority'), label: '优先级', value: this.priority, select: (): void => { this.choosePriority() }, clear: () => { this.priority = '' } })
                  this.field({ icon: $r('app.media.ui_calendar'), label: '计划日期', value: this.scheduled, select: (): void => { this.chooseDate(false) }, clear: () => { this.scheduled = '' } })
                  this.field({ icon: $r('app.media.ui_deadline'), label: '截止日期', value: this.deadline, select: (): void => { this.chooseDate(true) }, clear: () => { this.deadline = '' } })
                }
                Divider().color(UiColor.outline)
                Button(this.saving ? '保存中…' : '保存任务').width('90%').height(48).backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary)
                  .enabled(!this.saving && !this.todoLoading && this.initialState.length > 0).margin({ top: 24, bottom: 32 }).onClick((): void => { this.saveTask() })
              }.width('100%').enabled(!this.saving)
            }.width('100%').layoutWeight(1).align(Alignment.TopStart)
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
