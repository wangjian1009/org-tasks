import { InternalLinkProcessor } from '../../ui/InternalLinkProcessor'
import { CoreContentBlock, CoreTextLink, CoreLinkValue } from '../../services/NativeCoreService'
import { OrgContentView } from '../OrgContentView'
import { LinkEditController } from '../LinkView'
import { TaskBlockController } from '../../ui/TaskBlockController'
import { UiColor } from '../../ui/Theme'

// 文本、普通列表和表格共用阅读外壳；readonly 只关闭修改入口，保留阅读与链接跳转。
@Component
export struct TaskBlockView {
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop block: CoreContentBlock
  @Prop @Watch('readonlyChanged') readonly: boolean = false
  @Prop disabled: boolean = false
  @Prop revision: string = ''
  @Prop contentBackground: string = UiColor.taskCard
  @Prop ownerKey: string = ''
  @Prop placeholder: string = '文本'
  editor: TaskBlockController = new TaskBlockController()
  linkEditor: LinkEditController = new LinkEditController()
  begin: (block: CoreContentBlock) => Promise<boolean> = async () => true
  save: (block: CoreContentBlock, source: string) => Promise<boolean> = async () => false
  changeLink: ((block: CoreContentBlock, link: CoreTextLink, value: CoreLinkValue | null) => Promise<void>) | undefined = undefined
  editingChanged: (editing: boolean) => void = () => {}
  linkEditingChanged: (editing: boolean) => void = () => {}
  @State editing: boolean = false
  @State draft: string = ''
  @State saving: boolean = false
  private original: CoreContentBlock | undefined = undefined
  private inputKey: string = ''
  private alive: boolean = true
  private pending: Promise<boolean> | undefined = undefined

  aboutToAppear() { this.alive = true; this.inputKey = `block_${this.ownerKey}_${this.getUniqueId()}` }
  aboutToDisappear() { this.alive = false; this.editor.release(this.inputKey); if (this.editing) this.editingChanged(false) }

  readonlyChanged() { if (this.readonly) this.cancel() }

  async edit() {
    if (this.readonly || this.disabled || this.editing) return
    const revision = this.revision
    if (!await this.editor.finish() || revision !== this.revision || !await this.begin(this.block)) return
    if (!this.alive || this.readonly || this.disabled) return
    this.original = this.block
    this.draft = this.block.source
    if (!await this.editor.begin(this.inputKey, async (): Promise<boolean> => this.finish(), (): void => { this.cancel() })) return
    this.editing = true; this.editingChanged(true)
  }

  async finish(): Promise<boolean> {
    if (this.pending) return this.pending
    if (!this.editing || !this.original) return true
    if (this.readonly || this.disabled) return false
    const block = this.original
    const source = this.draft
    this.saving = true
    this.pending = source === block.source ? Promise.resolve(true) : this.save(block, source)
    try {
      if (!await this.pending) return false
      if (this.alive) { this.editing = false; this.editingChanged(false) }
      this.editor.release(this.inputKey)
      return true
    } finally { this.pending = undefined; if (this.alive) this.saving = false }
  }

  cancel() {
    if (this.saving) return
    this.editing = false; this.editingChanged(false); this.editor.release(this.inputKey)
  }

  build() {
    Column({ space: 4 }) {
      if (this.editing) {
        TextArea({ text: this.draft, placeholder: this.placeholder }).id(this.inputKey).defaultFocus(true)
          .width('100%').height('auto').minLines(1).maxLines(1000).fontSize(14).fontColor(UiColor.text)
          .backgroundColor(Color.Transparent).padding(0).borderRadius(0).enabled(!this.readonly && !this.saving && !this.disabled)
          .onChange((value: string): void => { this.draft = value })
        Row({ space: 12 }) {
          Button('取消').height(36).fontColor(UiColor.secondary).backgroundColor(Color.Transparent)
            .enabled(!this.saving).onClick((): void => { this.cancel() })
          Button('保存').height(36).fontColor(UiColor.primary).backgroundColor(Color.Transparent)
            .enabled(!this.readonly && !this.saving && !this.disabled).onClick((): void => { this.finish() })
        }.width('100%').justifyContent(FlexAlign.End)
      } else {
        OrgContentView({ internalLinkProcessor: this.internalLinkProcessor, fragment: this.block.html, revision: this.revision, embedded: true, embeddedPadding: 0,
          editable: !this.readonly && !this.disabled && this.changeLink !== undefined,
          linkEditor: this.linkEditor, linkEditingChanged: this.linkEditingChanged,
          changeLink: this.changeLink ? (link: CoreTextLink, value: CoreLinkValue | null): Promise<void> => this.changeLink!(this.block, link, value) : undefined,
          contentBackground: this.contentBackground, activate: this.readonly ? undefined : (): void => { this.edit() } }).width('100%')
      }
    }.width('100%')
  }
}
