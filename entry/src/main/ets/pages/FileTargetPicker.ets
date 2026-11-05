import { router } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { EmptyState, ListSectionHeader } from '../components/Controls'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
import { NotebookGroup, NotebookService } from '../services/NotebookService'
import { CoreBridgeError, CoreOrgFileMetadata, coreErrorMessage } from '../services/NativeCoreService'
import { configuredFileTarget, FileTargetKind, FileTargetService } from '../services/FileTargetService'
import { UiColor } from '../ui/Theme'

interface PickerParams { kind?: string }

@Entry
@Component
struct FileTargetPicker {
  @State groups: NotebookGroup[] = []
  @State loading: boolean = true
  @State saving: boolean = false
  @State message: string = ''
  @State kind: FileTargetKind = 'inbox'
  @State config: AppConfig = DEFAULT_CONFIG
  @State drawerOpen: boolean = false

  onPageShow() { this.load() }
  onBackPress(): boolean { return this.saving }

  async load() {
    this.loading = true
    this.message = ''
    try {
      const params = router.getParams() as PickerParams | undefined
      if (params?.kind === 'someday' || params?.kind === 'memo') this.kind = params.kind
      this.config = await AppConfigService.load(getContext(this))
      this.groups = await NotebookService.list(this.config.repos, this.config.todoDefaults)
      this.groups = this.groups.map((group: NotebookGroup): NotebookGroup => ({
        repoId: group.repoId, configId: group.configId, name: group.name, rootDirectory: group.rootDirectory,
        files: group.files.filter((file: CoreOrgFileMetadata) => !file.isIgnore), message: group.message
      }))
    } catch (e) {
      this.message = `读取文件列表失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally {
      this.loading = false
    }
  }

  title(): string {
    return this.kind === 'inbox' ? '选择收件箱文件' : this.kind === 'someday' ? '选择某天文件' : '选择备忘文件'
  }

  async choose(group: NotebookGroup, file: CoreOrgFileMetadata) {
    await this.saveTarget(group.configId, file.path)
  }

  selected(group: NotebookGroup, file: CoreOrgFileMetadata): boolean {
    const target = configuredFileTarget(this.config, this.kind)
    return target.repoId === group.configId && target.path === file.path
  }

  async saveTarget(repoId: string, path: string) {
    if (this.saving || this.loading) return
    this.saving = true
    try {
      await FileTargetService.select(getContext(this), this.kind, repoId, path)
      router.back()
    } catch (e) {
      this.message = `保存文件入口失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally { this.saving = false }
  }

  build() {
    Column() {
      AppShell({ title: this.title(), back: true, busy: this.saving, drawerOpen: $drawerOpen, backAction: (): void => { if (!this.saving) router.back() } }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在读取文件', busy: true })
          } else if (this.message) {
            EmptyState({ title: '读取文件失败', detail: this.message, actionLabel: '重试', action: (): void => { this.load() } })
          } else if (this.groups.length === 0) {
            EmptyState({ title: '没有可选文件', detail: '请先配置仓库和 Org 文件。' })
          } else {
            List() {
              ForEach(this.groups, (group: NotebookGroup) => {
                ListItemGroup({ header: this.repositoryHeader(group) }) {
                  if (group.files.length === 0) {
                    ListItem() { Text(group.message || '暂无可选 Org 文件').fontSize(13).fontColor(UiColor.secondary).padding(16) }
                  }
                  ForEach(group.files, (file: CoreOrgFileMetadata) => {
                    ListItem() {
                      Row({ space: 12 }) {
                        Column({ space: 4 }) {
                          Text(file.title || file.path).fontSize(16).fontColor(UiColor.text).width('100%')
                          Text(file.path).fontSize(13).fontColor(UiColor.secondary).width('100%')
                        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                        if (this.selected(group, file)) { Text('已选').fontSize(13).fontColor(UiColor.primary) }
                      }.width('100%').padding({ top: 14, bottom: 14 })
                        .id(`file_target_${group.configId}_${file.path}`)
                        .onClick((): void => { this.choose(group, file) })
                    }
                  }, (file: CoreOrgFileMetadata) => `${file.repoId}:${file.path}`)
                }
              }, (group: NotebookGroup) => `${group.configId}:${group.name}`)
            }.width('100%').layoutWeight(1).padding({ left: 20, right: 20, bottom: 16 })
          }
          if (!this.loading) {
            Button(this.saving ? '保存中…' : '清除选择').id('clear_file_target').width('90%').height(48)
              .backgroundColor(UiColor.selected).fontColor(UiColor.onSelected).margin({ top: 8, bottom: 16 })
              .onClick((): void => { this.saveTarget('', '') })
          }
        }.width('100%').height('100%').enabled(!this.saving)
      }
    }.width('100%').height('100%')
  }

  @Builder
  repositoryHeader(group: NotebookGroup) {
    ListSectionHeader({ title: group.name })
  }
}
