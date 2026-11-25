import { localizedText } from '../../ui/LocalizedText'
import { fileIo } from '@kit.CoreFileKit'
import { UiColor, repositoryName } from '../../ui/Theme'
import { coreErrorMessage, CoreBridgeError } from '../../services/NativeCoreService'

@Component
export struct LocalDirectorySheet {
  @Prop initialDirectory: string = ''
  @Link busy: boolean
  @State directory: string = ''
  @State folders: string[] = []
  @State loading: boolean = true
  @State message: string = ''
  @State creating: boolean = false
  @State folderName: string = ''
  private request: number = 0
  private disposed: boolean = false
  selected: (directory: string) => void = () => {}

  aboutToAppear() { this.disposed = false; this.openInitialDirectory() }
  aboutToDisappear() { this.disposed = true; this.request++ }

  async openInitialDirectory() {
    const request = ++this.request
    const initial = this.initialDirectory.trim()
    let accessible = false
    try { accessible = initial.length > 0 && (await fileIo.stat(initial)).isDirectory() }
    catch (_) {}
    if (this.disposed || request !== this.request) return
    await this.browse(accessible ? initial : this.getUIContext().getHostContext()!.filesDir)
    if (initial && !accessible && !this.disposed && this.request === request + 1) {
      this.message = localizedText($r('app.string.text_the_original_folder_is_unavailable_select_a'))
    }
  }

  parent(): string {
    const parts = this.directory.split('/').filter((part: string) => part.length > 0)
    parts.pop()
    return `/${parts.join('/')}`
  }

  async browse(path: string) {
    if (this.busy || this.disposed) return
    const request = ++this.request
    this.loading = true
    this.message = ''
    try {
      const names = await fileIo.listFile(path, { recursion: false })
      const folders: string[] = []
      for (const name of names) {
        try { if ((await fileIo.stat(`${path === '/' ? '' : path}/${name}`)).isDirectory()) folders.push(name) }
        catch (_) {}
      }
      if (request !== this.request) return
      this.directory = path
      this.folders = folders.sort((left: string, right: string) => left.localeCompare(right))
      this.creating = false
      this.folderName = ''
    } catch (e) { if (request === this.request) this.message = localizedText($r('app.string.text_could_not_browse_this_directory'), String(coreErrorMessage(e as CoreBridgeError))) }
    finally { if (request === this.request) this.loading = false }
  }

  async createFolder() {
    if (this.busy || this.loading) return
    const name = this.folderName.trim()
    if (!name || name === '.' || name === '..' || /[/\\\x00-\x1f\x7f]/.test(name)) {
      this.message = localizedText($r('app.string.text_please_enter_a_valid_folder_name_without'))
      return
    }
    const destination = `${this.directory === '/' ? '' : this.directory}/${name}`
    this.busy = true
    this.message = ''
    try {
      await fileIo.mkdir(destination)
    } catch (e) {
      this.message = localizedText($r('app.string.text_couldn_t_create_the_folder'), String(coreErrorMessage(e as CoreBridgeError)))
      return
    } finally { this.busy = false }
    await this.browse(destination)
  }

  build() {
    Column() {
      Text($r('app.string.text_select_directory')).fontSize(18).fontColor(UiColor.text).width('100%').padding({ left: 20, right: 48, top: 12, bottom: 20 })
      Divider().color(UiColor.divider)
      Row() {
        Button($r('app.string.text_apply_file')).height(44).fontSize(14).backgroundColor(Color.Transparent).fontColor(UiColor.primary)
          .onClick((): void => { this.browse(this.getUIContext().getHostContext()!.filesDir) })
        Blank()
        Button($r('app.string.text_new_folder')).height(44).fontSize(14).backgroundColor(Color.Transparent).fontColor(UiColor.primary)
          .enabled(!this.loading && !this.busy && this.directory.length > 0)
          .onClick((): void => { this.creating = !this.creating; this.folderName = '' })
      }.width('100%').padding({ left: 8, right: 8 }).enabled(!this.busy)
      Row({ space: 8 }) {
        Button('‹').height(44).width(44).fontSize(26).backgroundColor(Color.Transparent).fontColor(UiColor.text)
          .enabled(!this.loading && !this.busy && this.directory !== '/' && this.directory.length > 0)
          .accessibilityText($r('app.string.text_upper_directory')).onClick((): void => { this.browse(this.parent()) })
        Text(this.directory || localizedText($r('app.string.text_reading'))).fontSize(13).fontColor(UiColor.secondary).layoutWeight(1).maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%').padding({ right: 20 })
      if (this.message) {
        Row() {
          Text(this.message).fontSize(13).lineHeight(21).fontColor(UiColor.error).layoutWeight(1)
          Button($r('app.string.text_retry')).height(44).fontSize(14).backgroundColor(Color.Transparent).fontColor(UiColor.primary)
            .onClick((): void => { if (this.directory) this.browse(this.directory); else this.openInitialDirectory() })
        }.width('100%').padding({ left: 20, right: 12 })
      }
      if (this.creating) {
        Row({ space: 8 }) {
          TextInput({ text: this.folderName, placeholder: localizedText($r('app.string.text_folder_name')) }).layoutWeight(1).height(44)
            .backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary)
            .onChange((value: string): void => { this.folderName = value })
          Button(this.busy ? localizedText($r('app.string.text_creating')) : localizedText($r('app.string.text_create'))).height(44).fontSize(14).backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary)
            .onClick((): void => { this.createFolder() })
        }.width('100%').padding({ left: 20, right: 20, bottom: 12 }).enabled(!this.busy)
      }
      if (this.loading) {
        Column() { LoadingProgress().width(32).height(32).color(UiColor.primary) }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        List() {
          if (this.folders.length === 0) {
            ListItem() { Text($r('app.string.text_there_are_no_subfolders_in_this_directory')).fontSize(14).fontColor(UiColor.secondary).padding(16) }
          }
          ForEach(this.folders, (name: string) => {
            ListItem() {
              Row({ space: 12 }) {
                Image($r('app.media.ui_folder')).width(20).height(20).fillColor(UiColor.secondary)
                Text(name).fontSize(16).fontColor(UiColor.text).layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                Image($r('app.media.ui_next')).width(16).height(16).fillColor(UiColor.secondary)
              }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 4, right: 4, top: 12, bottom: 12 })
                .border({ width: { bottom: 0.5 }, color: UiColor.divider })
                .onClick((): void => { this.browse(`${this.directory === '/' ? '' : this.directory}/${name}`) })
            }
          }, (name: string) => name)
        }.width('100%').layoutWeight(1).padding({ left: 20, right: 20 }).enabled(!this.busy)
      }
      Column({ space: 12 }) {
        Row() {
          Text($r('app.string.text_current_directory')).fontSize(13).fontColor(UiColor.secondary)
          Blank()
          Text(repositoryName(this.directory)).fontSize(13).fontColor(UiColor.text).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '70%' })
        }.width('100%')
        Button($r('app.string.text_use_this_directory')).width('100%').height(48).borderRadius(12).backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary)
          .enabled(!this.busy && !this.loading && this.directory.length > 0)
          .onClick((): void => { this.selected(this.directory) })
      }.width('100%').padding({ left: 20, right: 20, top: 16, bottom: 28 })
    }.width('100%').height('100%')
  }
}
