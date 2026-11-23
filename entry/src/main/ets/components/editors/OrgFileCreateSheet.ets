import { CoreTask, CoreTaskOperationGroup, CoreBridgeError, coreErrorMessage } from '../../services/NativeCoreService'
import { OrgFileCreateService } from '../../services/OrgFileCreateService'
import { OrgFileRepositoryOption, OrgFileRegionDraft, OrgFileCreateInput, orgFileInputError } from '../../ui/OrgFileCreatePresentation'
import { window } from '@kit.ArkUI'
import { UiColor } from '../../ui/Theme'

@Component
export struct OrgFileCreateSheet {
  source: CoreTask | undefined = undefined
  @Prop converting: boolean = false
  @Prop titleHidden: boolean = false
  @Prop repositoryHidden: boolean = false
  @Link generating: boolean
  @Prop repositories: OrgFileRepositoryOption[] = []
  @Prop initialRepoId: string = ''
  @Prop initialRegion: string = ''
  @Prop initialName: string = ''
  @Prop busy: boolean = false
  @Prop message: string = ''
  @State repoId: string = ''
  @State region: string = ''
  @State addingRegion: boolean = false
  @State newRegionName: string = ''
  @State newRegions: OrgFileRegionDraft[] = []
  @State title: string = ''
  @State projectName: string = ''
  @State fileName: string = ''
  @State inputError: string = ''
  private hostWindow: window.Window | undefined = undefined
  private active: boolean = false
  typingChanged: (typing: boolean) => void = () => {}
  private keyboardChanged = (height: number): void => { if (this.active) this.typingChanged(height > 0) }
  generated: (group: CoreTaskOperationGroup) => void = () => {}
  cancel: () => void = () => {}

  async aboutToAppear(): Promise<void> {
    this.active = true
    this.initializeFields()
    try {
      const current = await window.getLastWindow(this.getUIContext().getHostContext()!)
      if (!this.active) return
      this.hostWindow = current
      this.hostWindow.on('keyboardHeightChange', this.keyboardChanged)
    } catch (_) { /* 键盘监听不可用时保留面板的正常编辑。 */ }
  }

  aboutToDisappear(): void {
    this.active = false
    try { this.hostWindow?.off('keyboardHeightChange', this.keyboardChanged) } catch (_) {}
    this.typingChanged(false)
  }

  initializeFields(): void {
    this.repoId = this.repositoryHidden || this.repositories.some(option => option.repoId === this.initialRepoId)
      ? this.initialRepoId : this.repositories[0]?.repoId ?? ''
    this.region = this.defaultRegion()
    this.projectName = this.initialName
  }

  defaultRegion(): string {
    const options = this.regionOptions()
    return this.repoId === this.initialRepoId && options.includes(this.initialRegion) ? this.initialRegion : options[0] ?? ''
  }

  selectRegion(index: number): void {
    if (this.isBusy()) return
    const options = this.regionOptions()
    if (index === options.length + 1) {
      this.addingRegion = true
      this.newRegionName = ''
      this.inputError = ''
    } else {
      this.region = index > 0 ? options[index - 1] ?? '' : ''
    }
  }

  isBusy(): boolean { return this.busy || this.generating }

  async submit(): Promise<void> {
    if (this.isBusy()) return
    if (this.addingRegion && !this.saveRegion()) return
    if (this.converting && !this.source) { this.inputError = '原记录已失效，请重新打开'; return }
    const input: OrgFileCreateInput = {
      repoId: this.repoId, region: this.region,
      title: this.titleHidden ? (this.projectName.trim() ? this.projectName : this.initialName) : this.title,
      projectName: this.projectName, fileName: this.fileName
    }
    this.inputError = orgFileInputError(input)
    if (this.inputError) return
    this.generating = true
    try {
      const group = await OrgFileCreateService.operationGroup(this.getUIContext().getHostContext()!, this.source, input)
      if (this.active) this.generated(group)
    } catch (error) { if (this.active) this.inputError = coreErrorMessage(error as CoreBridgeError) }
    finally { this.generating = false }
  }

  selectRepository(index: number): void {
    const next = this.repositories[index]?.repoId ?? ''
    if (this.isBusy() || this.repositoryHidden || !next || next === this.repoId) return
    this.repoId = next
    this.region = this.defaultRegion()
    this.addingRegion = false
    this.newRegionName = ''
    this.inputError = ''
  }

  regionOptions(): string[] {
    const existing = this.repositories.find(option => option.repoId === this.repoId)?.regions ?? []
    return Array.from(new Set(existing.concat(this.newRegions.filter(item => item.repoId === this.repoId).map(item => item.name)))).sort()
  }

  saveRegion(): boolean {
    if (this.isBusy()) return false
    const name = this.newRegionName.trim()
    if (!name) { this.inputError = '请输入分类名称'; return false }
    if (/[\r\n\u0000]/.test(name)) { this.inputError = '分类名称不能包含换行或控制字符'; return false }
    if (!this.regionOptions().includes(name)) this.newRegions = [...this.newRegions, { repoId: this.repoId, name }]
    this.region = name
    this.addingRegion = false
    this.newRegionName = ''
    this.inputError = ''
    return true
  }

  @Builder
  regionEditor() {
    Column({ space: 18 }) {
      Row() {
        Text('新建分类').fontSize(20).fontWeight(FontWeight.Medium).fontColor(UiColor.text).layoutWeight(1)
        Button('取消').id('project_create_region_cancel').height(44).fontColor(UiColor.secondary)
          .backgroundColor(Color.Transparent).enabled(!this.isBusy()).onClick((): void => {
            this.addingRegion = false; this.newRegionName = ''; this.inputError = ''
          })
      }.width('100%')
      Text(this.repositories.find(option => option.repoId === this.repoId)?.name || '')
        .fontSize(14).fontColor(UiColor.secondary).width('100%')
      TextInput({ text: this.newRegionName, placeholder: '分类名称' }).id('project_create_region_name')
        .height(48).fontSize(16).fontColor(UiColor.text).backgroundColor('#414542').enabled(!this.isBusy())
        .onChange((value: string): void => { this.newRegionName = value })
      if (this.inputError) { Text(this.inputError).fontSize(14).fontColor(UiColor.error).width('100%') }
      Button('添加分类').id('project_create_region_save').width('100%').height(48).backgroundColor(UiColor.primary)
        .fontColor(UiColor.onPrimary).enabled(!this.isBusy()).onClick((): void => { this.saveRegion() })
    }.width('100%')
  }

  build() {
    // FIT_CONTENT 面板内的 Scroll 需明确视口高度，百分比约束会循环测量为零。
    Scroll() {
      Column({ space: 16 }) {
        if (this.addingRegion) {
          this.regionEditor()
        } else {
          Row() {
            Text(this.converting ? '转换为项目' : '新增文件').fontSize(20).fontWeight(FontWeight.Medium)
              .fontColor(UiColor.text).layoutWeight(1)
            Button('取消').id('project_create_cancel').height(44).fontColor(UiColor.secondary)
              .backgroundColor(Color.Transparent).enabled(!this.isBusy()).onClick(this.cancel)
          }.width('100%')
          if (this.converting) {
            Text('正文与子条目会保留到新项目。').fontSize(14).fontColor(UiColor.secondary).width('100%')
          }
          if (!this.repositoryHidden) {
            Row({ space: 12 }) {
              Text('仓库').fontSize(16).fontColor(UiColor.text).width(64)
              Select(this.repositories.map((option: OrgFileRepositoryOption): SelectOption => ({ value: option.name })))
                .id('project_create_repository').selected(Math.max(0, this.repositories.findIndex(option => option.repoId === this.repoId)))
                .value(this.repositories.find(option => option.repoId === this.repoId)?.name || '选择仓库')
                .layoutWeight(1).height(48).font({ size: 14 }).fontColor(UiColor.text).backgroundColor('#414542')
                .borderRadius(12).padding({ left: 12, right: 12 }).accessibilityText('选择仓库')
                .enabled(!this.isBusy()).onSelect((index: number): void => { this.selectRepository(index) })
            }.width('100%')
          }
          Row({ space: 12 }) {
            Text('分类').fontSize(16).fontColor(UiColor.text).width(64)
            Select(['无'].concat(this.regionOptions(), ['新建分类']).map((value: string): SelectOption => ({ value })))
              .id('project_create_region').selected(Math.max(0, this.regionOptions().indexOf(this.region) + 1))
              .value(this.region || '无').layoutWeight(1).height(48).font({ size: 14 })
              .fontColor(UiColor.text).backgroundColor('#414542').borderRadius(12).padding({ left: 12, right: 12 })
              .enabled(!this.isBusy() && !!this.repoId).accessibilityText('选择分类')
              .onSelect((index: number): void => { this.selectRegion(index) })
          }.width('100%')
          if (!this.titleHidden) {
            Row({ space: 12 }) {
              Text('标题').fontSize(16).fontColor(UiColor.text).width(64)
              TextInput({ text: this.title }).id('project_create_title').height(48).layoutWeight(1)
                .fontSize(16).fontColor(UiColor.text).backgroundColor('#414542').borderRadius(12)
                .accessibilityText('标题').enabled(!this.isBusy()).onChange((value: string): void => { this.title = value })
            }.width('100%')
          }
          Row({ space: 12 }) {
            Text('项目名称').fontSize(16).fontColor(UiColor.text).width(64)
            TextInput({ text: this.projectName, placeholder: '选填' }).id('project_create_name').height(48).layoutWeight(1)
              .fontSize(16).fontColor(UiColor.text).backgroundColor('#414542').borderRadius(12)
              .enabled(!this.isBusy()).accessibilityText('项目名称')
              .onChange((value: string): void => { this.projectName = value })
          }.width('100%')
          Row({ space: 12 }) {
            Text('文件名').fontSize(16).fontColor(UiColor.text).width(64)
            TextInput({ text: this.fileName, placeholder: '默认同标题' }).id('project_create_filename').height(48).layoutWeight(1)
              .fontSize(16).fontColor(UiColor.text).backgroundColor('#414542').borderRadius(12)
              .enabled(!this.isBusy()).accessibilityText('文件名')
              .onChange((value: string): void => { this.fileName = value })
          }.width('100%')
          if (this.inputError || this.message) {
            Text(this.inputError || this.message).fontSize(14).fontColor(UiColor.error).width('100%')
          }
          Button(this.isBusy() ? '正在创建…' : this.converting && !!this.projectName.trim() ? '创建项目' : '创建文件')
            .id('project_create_submit').width('100%').height(48)
            .fontSize(16).fontColor(UiColor.onPrimary).backgroundColor(UiColor.primary)
            .enabled(!this.isBusy()).onClick((): void => { this.submit() })
        }
      }.width('100%').padding({ left: 20, right: 20, top: 16, bottom: 24 }).backgroundColor('#363A38')
    }.width('100%').height((this.addingRegion ? 264 : 404 + (this.repositoryHidden ? 0 : 64) -
      (this.titleHidden ? 64 : 0) + (this.converting ? 36 : 0)) +
      (this.inputError || this.message ? 60 : 0)).align(Alignment.Top).scrollBar(BarState.Off)
  }
}
