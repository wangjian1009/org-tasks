import { common } from '@kit.AbilityKit'
import { formBindingData, formProvider } from '@kit.FormKit'
import { MemoCardData, memoCardData, MemoCardService } from '../services/MemoCardService'
import { CoreBridgeError, coreErrorMessage } from '../services/NativeCoreService'
import { IconButton } from '../components/Controls'
import { UiColor } from '../ui/Theme'

interface MemoCardTagOption { tag: string; label: string }

@Entry({ useSharedStorage: true })
@Component
struct MemoCardConfig {
  @LocalStorageProp('memoCardFormId') formId: string = ''
  @State selectedTag: string = ''
  @State options: MemoCardTagOption[] = []
  @State preview: MemoCardData = memoCardData([], '', '正在读取备忘…')
  @State loading: boolean = true
  @State previewLoading: boolean = false
  @State available: boolean = false
  @State working: boolean = false
  @State message: string = ''
  private requestId: number = 0
  private persisted: boolean = false

  aboutToAppear(): void { this.load() }

  async load(): Promise<void> {
    this.loading = true
    this.message = ''
    try {
      const context = this.getUIContext().getHostContext()!
      this.selectedTag = await MemoCardService.loadTag(context, this.formId)
      const snapshot = await MemoCardService.snapshot(context, '')
      const tags = snapshot.tags.slice()
      if (this.selectedTag && !tags.includes(this.selectedTag)) tags.push(this.selectedTag)
      const all: MemoCardTagOption = { tag: '', label: '全部备忘' }
      this.options = [all].concat(tags.map((tag: string): MemoCardTagOption => ({ tag, label: tag })))
      this.available = snapshot.available
      if (this.selectedTag) await this.selectTag(this.selectedTag)
      else this.preview = snapshot.data
    } catch (error) {
      this.available = false
      this.message = coreErrorMessage(error as CoreBridgeError)
      this.preview = memoCardData([], this.selectedTag, '暂时无法读取备忘')
    } finally { this.loading = false }
  }

  async selectTag(tag: string): Promise<void> {
    if (this.working) return
    const request = ++this.requestId
    this.selectedTag = tag
    this.persisted = false
    this.message = ''
    this.previewLoading = true
    this.preview = memoCardData([], tag, '正在读取备忘…')
    try {
      const snapshot = await MemoCardService.snapshot(this.getUIContext().getHostContext()!, tag)
      if (request !== this.requestId) return
      this.preview = snapshot.data
      this.available = snapshot.available
    } catch (error) {
      if (request !== this.requestId) return
      this.available = false
      this.message = coreErrorMessage(error as CoreBridgeError)
      this.preview = memoCardData([], tag, '暂时无法读取备忘')
    } finally { if (request === this.requestId) this.previewLoading = false }
  }

  async confirm(): Promise<void> {
    if (this.working || this.loading || this.previewLoading || !this.available) return
    this.working = true
    this.message = ''
    try {
      const context = this.getUIContext().getHostContext()!
      const snapshot = await MemoCardService.snapshot(context, this.selectedTag)
      if (!snapshot.available) throw new Error(snapshot.data.memoCardMessage)
      await MemoCardService.saveTag(context, this.formId, this.selectedTag)
      this.persisted = true
      await formProvider.updateForm(this.formId, formBindingData.createFormBindingData(snapshot.data))
      await (context as common.UIAbilityContext).terminateSelf()
    } catch (error) {
      this.message = `${this.persisted ? '设置已保存，更新卡片或返回失败' : '保存失败'}：${coreErrorMessage(error as CoreBridgeError)}`
    } finally { this.working = false }
  }

  async cancel(): Promise<void> {
    if (this.working) return
    ++this.requestId
    try { await (this.getUIContext().getHostContext() as common.UIAbilityContext).terminateSelf() }
    catch (_) { this.message = '返回失败，请重试' }
  }

  onBackPress(): boolean { this.cancel(); return true }

  @Builder
  previewCard() {
    Column() {
      Row() {
        Text(this.preview.memoCardTitle).fontSize(16).fontWeight(FontWeight.Medium).fontColor('#FFF8DC')
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('+').fontSize(28).fontColor('#FFF8DC')
      }.width('100%').height('25%').padding({ left: 12, right: 12 }).backgroundColor('#F4BF35')
      Column() {
        ForEach([this.preview.memoCardItem1, this.preview.memoCardItem2, this.preview.memoCardItem3], (title: string, index: number) => {
          if (title.length > 0) {
            Column() {
              Row({ space: 8 }) {
                Rect().width(3).height(14).radius(1.5).fill('#F2C400')
                Text(title).fontSize(14).fontColor('#E4E0D5').layoutWeight(1)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.width('100%').height(40).padding({ left: 14, right: 12 })
              if (index < 2) {
                Row() { Rect().width('100%').height(0.5).fill('#39311B') }
                  .width('100%').height(0.5).padding({ left: 25, right: 12 })
              }
            }.width('100%').flexShrink(0)
          }
        }, (title: string, index: number): string => `${index}:${title}`)
        if (!this.preview.memoCardItem1 && !this.preview.memoCardItem2 && !this.preview.memoCardItem3) {
          Text(this.preview.memoCardMessage).width('100%').fontSize(13).fontColor('#AFA98D')
            .padding({ left: 14, right: 12, top: 14 }).maxLines(2)
        }
      }.width('100%').height('75%').clip(true)
    }.width('100%').height(148).backgroundColor('#211A08').borderRadius(22).clip(true)
      .accessibilityText('卡片预览')
  }

  build() {
    Column() {
      Row() {
        IconButton({ icon: $r('app.media.ui_back'), label: '取消编辑', disabled: this.working,
          action: (): void => { this.cancel() } })
        Text('编辑').fontSize(22).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
      }.width('100%').height(64).padding({ left: 4, right: 16 })
      Text(this.preview.memoCardTitle).fontSize(22).fontWeight(FontWeight.Bold).fontColor(UiColor.text)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 16, bottom: 24 })
      Column() { this.previewCard() }.width('100%').constraintSize({ maxWidth: 400 }).padding({ left: 32, right: 32 })
      Text('选择标签，设置卡片显示的备忘').width('100%').fontSize(14).fontColor(UiColor.secondary)
        .padding({ left: 24, right: 24, top: 24, bottom: 12 })
      if (this.message) {
        Text(this.message).fontSize(13).fontColor(UiColor.error).width('100%').padding({ left: 24, right: 24 })
        Button('重新读取').fontSize(14).backgroundColor(Color.Transparent).fontColor(UiColor.primary)
          .enabled(!this.working && !this.loading && !this.previewLoading).onClick((): void => { this.load() })
      }
      if (this.loading) {
        LoadingProgress().width(32).height(32).color(UiColor.primary).margin(16)
      }
      List() {
        ForEach(this.options, (option: MemoCardTagOption) => {
          ListItem() {
            Row({ space: 12 }) {
              Image($r('app.media.ui_tags')).width(22).height(22)
              Text(option.label).fontSize(18).fontColor(UiColor.text).layoutWeight(1).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.selectedTag === option.tag ? '✓' : '').fontSize(18).fontColor('#211A08')
                .width(24).height(24).textAlign(TextAlign.Center).borderRadius(12)
                .backgroundColor(this.selectedTag === option.tag ? '#F2C400' : Color.Transparent)
            }.width('100%').height(52).padding({ left: 16, right: 16 })
              .enabled(!this.loading && !this.working)
              .accessibilityText(`${option.label}，${this.selectedTag === option.tag ? '已选中' : '未选中'}`)
              .onClick((): void => { this.selectTag(option.tag) })
          }
        }, (option: MemoCardTagOption): string => option.tag)
      }.width('100%').layoutWeight(1).backgroundColor(UiColor.container).borderRadius(20).clip(true)
        .divider({ strokeWidth: 0.5, color: UiColor.outline, startMargin: 50, endMargin: 16 })
      Button(this.working ? '正在保存…' : '确定').width('100%').height(48).fontSize(17).fontColor('#211A08')
        .backgroundColor('#F2C400').margin({ top: 16, bottom: 16 })
        .enabled(!this.loading && !this.previewLoading && !this.working && this.available)
        .onClick((): void => { this.confirm() })
    }.width('100%').height('100%').padding({ left: 16, right: 16 }).backgroundColor(UiColor.surface)
  }
}
