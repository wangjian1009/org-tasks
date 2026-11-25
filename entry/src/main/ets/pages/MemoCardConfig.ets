import { localizedText } from '../ui/LocalizedText'
import { common } from '@kit.AbilityKit'
import { formBindingData, formProvider } from '@kit.FormKit'
import { MemoCardData, memoCardData, MemoCardService } from '../services/MemoCardService'
import { CoreBridgeError, coreErrorMessage } from '../services/NativeCoreService'
import { IconButton } from '../components/controls/IconButton'
import { UiColor } from '../ui/Theme'

interface MemoCardTagOption { tag: string; label: string }

@Entry({ useSharedStorage: true })
@Component
struct MemoCardConfig {
  @LocalStorageProp('memoCardFormId') formId: string = ''
  @State selectedTag: string = ''
  @State options: MemoCardTagOption[] = []
  @State preview: MemoCardData = memoCardData([], '', localizedText($r('app.string.text_reading_memo')))
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
      const all: MemoCardTagOption = { tag: '', label: localizedText($r('app.string.text_all_notes')) }
      this.options = [all].concat(tags.map((tag: string): MemoCardTagOption => ({ tag, label: tag })))
      this.available = snapshot.available
      if (this.selectedTag) await this.selectTag(this.selectedTag)
      else this.preview = snapshot.data
    } catch (error) {
      this.available = false
      this.message = coreErrorMessage(error as CoreBridgeError)
      this.preview = memoCardData([], this.selectedTag, localizedText($r('app.string.text_couldn_t_load_notes')))
    } finally { this.loading = false }
  }

  async selectTag(tag: string): Promise<void> {
    if (this.working) return
    const request = ++this.requestId
    this.selectedTag = tag
    this.persisted = false
    this.message = ''
    this.previewLoading = true
    this.preview = memoCardData([], tag, localizedText($r('app.string.text_reading_memo')))
    try {
      const snapshot = await MemoCardService.snapshot(this.getUIContext().getHostContext()!, tag)
      if (request !== this.requestId) return
      this.preview = snapshot.data
      this.available = snapshot.available
    } catch (error) {
      if (request !== this.requestId) return
      this.available = false
      this.message = coreErrorMessage(error as CoreBridgeError)
      this.preview = memoCardData([], tag, localizedText($r('app.string.text_couldn_t_load_notes')))
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
      this.message = `${this.persisted ? localizedText($r('app.string.text_settings_saved_cards_updated_or_returned_failed')) : localizedText($r('app.string.text_save_failed_2'))}：${coreErrorMessage(error as CoreBridgeError)}`
    } finally { this.working = false }
  }

  async cancel(): Promise<void> {
    if (this.working) return
    ++this.requestId
    try { await (this.getUIContext().getHostContext() as common.UIAbilityContext).terminateSelf() }
    catch (_) { this.message = localizedText($r('app.string.text_failed_to_return_try_again')) }
  }

  onBackPress(): boolean { this.cancel(); return true }

  @Builder
  previewCard() {
    Column() {
      Row() {
        Text(this.preview.memoCardTitle).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.memo_on_header'))
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Stack() {
          Rect().width(16).height(1.5).radius(0.75).fill($r('app.color.memo_on_header'))
          Rect().width(1.5).height(16).radius(0.75).fill($r('app.color.memo_on_header'))
        }.width(28).height(28)
      }.width('100%').height('25%').padding({ left: 12, right: 12 }).backgroundColor($r('app.color.memo_card_header'))
      Column() {
        ForEach([this.preview.memoCardItem1, this.preview.memoCardItem2, this.preview.memoCardItem3], (title: string, index: number) => {
          if (title.length > 0) {
            Column() {
              Row({ space: 8 }) {
                Rect().width(3).height(14).radius(1.5).fill($r('app.color.memo_accent'))
                Text(title).fontSize(14).fontColor($r('app.color.memo_card_text')).layoutWeight(1)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.width('100%').height(40).padding({ left: 14, right: 12 })
              if (index < 2) {
                Row() { Rect().width('100%').height(0.5).fill($r('app.color.memo_card_divider')) }
                  .width('100%').height(0.5).padding({ left: 25, right: 12 })
              }
            }.width('100%').flexShrink(0)
          }
        }, (title: string, index: number): string => `${index}:${title}`)
        if (!this.preview.memoCardItem1 && !this.preview.memoCardItem2 && !this.preview.memoCardItem3) {
          Text(this.preview.memoCardMessage).width('100%').fontSize(13).fontColor($r('app.color.memo_card_secondary'))
            .padding({ left: 14, right: 12, top: 14 }).maxLines(2)
        }
      }.width('100%').height('75%').clip(true)
    }.width('100%').height(148).backgroundColor($r('app.color.memo_card_surface')).borderRadius(22).clip(true)
      .accessibilityText($r('app.string.text_card_preview'))
  }

  build() {
    Column() {
      Row() {
        IconButton({ icon: $r('app.media.ui_back'), label: localizedText($r('app.string.text_cancel_edit')), disabled: this.working,
          action: (): void => { this.cancel() } })
        Text($r('app.string.text_edit')).fontSize(22).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
      }.width('100%').height(64).padding({ left: 4, right: 16 })
      Text(this.preview.memoCardTitle).fontSize(22).fontWeight(FontWeight.Bold).fontColor(UiColor.text)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 16, bottom: 24 })
      Column() { this.previewCard() }.width('100%').constraintSize({ maxWidth: 400 }).padding({ left: 32, right: 32 })
      Text($r('app.string.text_select_tab_set_the_memos_to_display')).width('100%').fontSize(14).fontColor(UiColor.secondary)
        .padding({ left: 24, right: 24, top: 24, bottom: 12 })
      if (this.message) {
        Text(this.message).fontSize(13).fontColor(UiColor.error).width('100%').padding({ left: 24, right: 24 })
        Button($r('app.string.text_reread')).fontSize(14).backgroundColor(Color.Transparent).fontColor($r('app.color.memo_accent'))
          .enabled(!this.working && !this.loading && !this.previewLoading).onClick((): void => { this.load() })
      }
      if (this.loading) {
        LoadingProgress().width(32).height(32).color($r('app.color.memo_accent')).margin(16)
      }
      List() {
        ForEach(this.options, (option: MemoCardTagOption) => {
          ListItem() {
            Row({ space: 12 }) {
              Image($r('app.media.ui_tags')).width(22).height(22)
              Text(option.label).fontSize(18).fontColor(UiColor.text).layoutWeight(1).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Row() {
                if (this.selectedTag === option.tag) {
                  Image($r('app.media.ui_done')).width(18).height(18).fillColor($r('app.color.memo_on_header'))
                    .accessibilityLevel('no')
                }
              }.width(24).height(24).justifyContent(FlexAlign.Center).borderRadius(12)
                .backgroundColor(this.selectedTag === option.tag ? $r('app.color.memo_card_header') : Color.Transparent)
            }.width('100%').height(52).padding({ left: 16, right: 16 })
              .enabled(!this.loading && !this.working)
              .accessibilityText(`${option.label}，${this.selectedTag === option.tag ? localizedText($r('app.string.text_selected')) : localizedText($r('app.string.text_not_selected'))}`)
              .onClick((): void => { this.selectTag(option.tag) })
          }
        }, (option: MemoCardTagOption): string => option.tag)
      }.width('100%').layoutWeight(1).backgroundColor(UiColor.container).borderRadius(20).clip(true)
        .divider({ strokeWidth: 0.5, color: UiColor.outline, startMargin: 50, endMargin: 16 })
      Button(this.working ? localizedText($r('app.string.text_saving_4')) : localizedText($r('app.string.text_ok'))).width('100%').height(48).fontSize(17).fontColor($r('app.color.memo_on_header'))
        .backgroundColor($r('app.color.memo_card_header')).margin({ top: 16, bottom: 16 })
        .enabled(!this.loading && !this.previewLoading && !this.working && this.available)
        .onClick((): void => { this.confirm() })
    }.width('100%').height('100%').padding({ left: 16, right: 16 }).backgroundColor(UiColor.surface)
  }
}
