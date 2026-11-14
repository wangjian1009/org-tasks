import { AppConfigService } from '../../services/AppConfigService'
import { NotebookGroup, NotebookService } from '../../services/NotebookService'
import { CoreBridgeError, CoreOrgFileMetadata, coreErrorMessage } from '../../services/NativeCoreService'
import { configuredFileTarget, FileTarget, FileTargetKind, FileTargetService, fileTargetName } from '../../services/FileTargetService'
import { EmptyState } from '../controls/EmptyState'
import { UiColor } from '../../ui/Theme'

@Component
export struct FileTargetSheet {
  @Prop kind: FileTargetKind = 'inbox'
  @Link busy: boolean
  @State groups: NotebookGroup[] = []
  @State loading: boolean = true
  @State message: string = ''
  @State selected: FileTarget | undefined = undefined
  private disposed: boolean = false
  saved: () => void = () => {}

  aboutToAppear() { this.disposed = false; this.load() }
  aboutToDisappear() { this.disposed = true }

  async load() {
    if (this.busy) return
    this.loading = true
    this.message = ''
    try {
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      const groups = await NotebookService.list(config)
      if (this.disposed) return
      this.groups = groups.map((group: NotebookGroup): NotebookGroup => ({
        repoId: group.repoId, configId: group.configId, name: group.name, rootDirectory: group.rootDirectory,
        files: group.files.filter((file: CoreOrgFileMetadata) => !file.isIgnore), message: group.message
      }))
      const target = this.selected ?? configuredFileTarget(config, this.kind)
      if (!target.path && !target.repoId) this.selected = { repoId: '', path: '' }
      else if (this.groups.some((group: NotebookGroup) => group.configId === target.repoId &&
        group.files.some((file: CoreOrgFileMetadata) => file.path === target.path))) this.selected = target
      else {
        this.selected = undefined
        this.message = '原选择已失效或暂时无法读取，请重新选择或重试'
      }
    } catch (e) { if (!this.disposed) this.message = `读取文件列表失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { if (!this.disposed) this.loading = false }
  }

  isSelected(repoId: string, path: string): boolean {
    return this.selected?.repoId === repoId && this.selected?.path === path
  }

  select(repoId: string, path: string) {
    if (this.busy || this.loading) return
    this.selected = { repoId, path }
  }

  async confirm() {
    if (!this.selected || this.busy || this.loading) return
    this.busy = true
    this.message = ''
    try {
      await FileTargetService.select(this.getUIContext().getHostContext()!, this.kind, this.selected.repoId, this.selected.path)
      this.saved()
    } catch (e) { this.message = `保存文件入口失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.busy = false }
  }

  @Builder
  choice(repoId: string, path: string, title: string) {
    Row({ space: 10 }) {
      Column({ space: 4 }) {
        Text(title).fontSize(16).fontColor(UiColor.text).width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (path) { Text(path).fontSize(12).fontColor(UiColor.secondary).width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }) }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.isSelected(repoId, path)) {
        Button(this.busy ? '保存中' : '确认').fontSize(14).width(58).height(32).padding(0)
          .borderRadius(10).backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary)
          .enabled(!this.busy).onClick((): void => { this.confirm() })
      }
    }.width('100%').constraintSize({ minHeight: 60 }).padding({ left: path ? 36 : 12, right: 10, top: 8, bottom: 8 })
      .backgroundColor(this.isSelected(repoId, path) ? '#3F514A' : Color.Transparent)
      .border({ width: this.isSelected(repoId, path) ? 1 : 0, color: UiColor.primary }).borderRadius(10)
      .accessibilityText(`${title}，${path}${this.isSelected(repoId, path) ? '，已选中，点击确认应用' : '，点击选择'}`)
      .enabled(!this.busy).onClick((): void => { this.select(repoId, path) })
  }

  @Builder
  repositoryHeading(group: NotebookGroup) {
    Row({ space: 8 }) {
      Image($r('app.media.ui_folder')).width(16).height(16).fillColor(UiColor.secondary).accessibilityLevel('no')
      Text(group.name).fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiColor.secondary)
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
    }.width('100%').constraintSize({ minHeight: 36 }).padding({ left: 12, right: 10, top: 2, bottom: 2 })
      .margin({ top: 28, bottom: 8 }).accessibilityText(`存储库，${group.name}`)
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Image($r('app.media.ui_folder')).width(24).height(24).accessibilityLevel('no')
        Text(`选择${fileTargetName(this.kind)}文件`).fontSize(20).fontColor(UiColor.text).fontWeight(FontWeight.Medium)
      }.width('100%').height(48).padding({ left: 16, right: 48 })
      Divider().color(UiColor.outline).margin({ left: 12, right: 12 })
      if (this.loading) {
        EmptyState({ title: '正在读取文件', busy: true })
      } else {
        List() {
          if (this.message) {
            ListItem() {
              Column({ space: 8 }) {
                Text(this.message).fontSize(13).lineHeight(21).fontColor(UiColor.error).width('100%')
                Button('重新读取').height(40).fontSize(14).backgroundColor(UiColor.selected).fontColor(UiColor.onSelected)
                  .onClick((): void => { this.load() })
              }.width('100%').padding(12)
            }
          }
          if (this.groups.length === 0) {
            ListItem() { Text('没有可选文件，请先在设置中配置存储库。').fontSize(14).fontColor(UiColor.secondary).padding(12) }
          }
          ForEach(this.groups, (group: NotebookGroup) => {
            ListItemGroup({ header: this.repositoryHeading(group) }) {
              if (group.message || group.files.length === 0) {
                ListItem() { Text(group.message || '暂无可选 Org 文件').fontSize(13).fontColor(group.message ? UiColor.error : UiColor.secondary).padding({ left: 36, right: 10, top: 8, bottom: 8 }) }
              }
              ForEach(group.files, (file: CoreOrgFileMetadata) => {
                ListItem() { this.choice(group.configId, file.path, file.title || file.path) }
              }, (file: CoreOrgFileMetadata) => `${group.configId}:${file.path}`)
            }
          }, (group: NotebookGroup) => group.configId)
          ListItem() { Column() { this.choice('', '', '不设置此入口') }.padding({ top: 24, bottom: 24 }) }
        }.width('100%').layoutWeight(1).padding({ left: 12, right: 12, bottom: 16 })
          .edgeEffect(EdgeEffect.None)
          .nestedScroll({ scrollForward: NestedScrollMode.SELF_ONLY, scrollBackward: NestedScrollMode.SELF_ONLY })
      }
    }.width('100%').height('100%').backgroundColor('#363A38').padding({ bottom: 8 })
  }
}
