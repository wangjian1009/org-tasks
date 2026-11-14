/** 桌面备忘服务卡片，数据由 MemoFormExtension 写入 FormBindingData。 */
const memoCardStorage: LocalStorage = new LocalStorage()

@Entry(memoCardStorage)
@Component
struct MemoCard {
  @LocalStorageProp('memoCardTitle') cardTitle: string = '全部备忘'
  @LocalStorageProp('memoCardItem1') item1: string = ''
  @LocalStorageProp('memoCardItem2') item2: string = ''
  @LocalStorageProp('memoCardItem3') item3: string = ''
  @LocalStorageProp('memoCardItemId1') itemId1: string = ''
  @LocalStorageProp('memoCardItemId2') itemId2: string = ''
  @LocalStorageProp('memoCardItemId3') itemId3: string = ''
  @LocalStorageProp('memoCardMessage') message: string = '正在读取备忘…'

  private openMemo(): void {
    postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { page: 'memo' } })
  }

  private createMemo(): void {
    postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { page: 'memo', memoAction: 'create' } })
  }

  private editMemo(index: number): void {
    const memoId = [this.itemId1, this.itemId2, this.itemId3][index]
    postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { page: 'memo', memoAction: 'edit', memoId } })
  }

  build() {
    Column() {
      Row() {
        Row() {
          Text(this.cardTitle).layoutWeight(1).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.memo_on_header')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).height('100%').onClick((): void => { this.openMemo() })
        Button({ type: ButtonType.Circle }) {
          Stack() {
            Rect().width(16).height(1.5).radius(0.75).fill($r('app.color.memo_on_header'))
            Rect().width(1.5).height(16).radius(0.75).fill($r('app.color.memo_on_header'))
          }.width(28).height(28)
        }.width(28).height(28).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('新增备忘').onClick((): void => { this.createMemo() })
      }.width('100%').height('25%').padding({ left: 12, right: 8 }).backgroundColor($r('app.color.memo_card_header'))
      Column() {
        // 直接在响应式列表中读取绑定字段，避免 Builder 值参数停留在首次空快照。
        ForEach([this.item1, this.item2, this.item3], (title: string, index: number) => {
          if (title.length > 0) {
            Column() {
              Row({ space: 8 }) {
                Rect().width(3).height(14).radius(1.5).fill($r('app.color.memo_accent'))
                Text(title).layoutWeight(1).fontSize(14).fontColor($r('app.color.memo_card_text'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.width('100%').height(40).padding({ left: 14, right: 12 })
                .onClick((): void => { this.editMemo(index) })
              if (index < 2) {
                Row() {
                  Rect().width('100%').height(0.5).fill($r('app.color.memo_card_divider'))
                }.width('100%').height(0.5).padding({ left: 25, right: 12 })
              }
            }.width('100%').flexShrink(0)
          }
        }, (title: string, index: number): string => `${index}:${title}`)
        if (this.item1.length === 0 && this.item2.length === 0 && this.item3.length === 0) {
          Text(this.message).width('100%').padding({ left: 14, right: 12, top: 14 })
            .fontSize(13).fontColor($r('app.color.memo_card_secondary')).maxLines(2)
            .onClick((): void => { this.openMemo() })
        }
      }.width('100%').height('75%').clip(true).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').backgroundColor($r('app.color.memo_card_surface')).clip(true)
  }
}
