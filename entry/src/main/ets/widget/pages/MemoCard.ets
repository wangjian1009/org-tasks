/** 桌面备忘服务卡片，数据由 MemoFormExtension 写入 FormBindingData。 */
@Entry
@Component
struct MemoCard {
  @LocalStorageProp('memoCardTitle') cardTitle: string = '全部备忘'
  @LocalStorageProp('memoCardItem1') item1: string = ''
  @LocalStorageProp('memoCardItem2') item2: string = ''
  @LocalStorageProp('memoCardItem3') item3: string = ''
  @LocalStorageProp('memoCardMessage') message: string = '正在读取备忘…'

  private openMemo(): void {
    postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { page: 'memo' } })
  }

  build() {
    Column() {
      Row() {
        Text(this.cardTitle).layoutWeight(1).fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor('#FFF8DC').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Button({ type: ButtonType.Circle }) {
          Stack() {
            Rect().width(16).height(1.5).radius(0.75).fill('#FFF8DC')
            Rect().width(1.5).height(16).radius(0.75).fill('#FFF8DC')
          }.width(28).height(28)
        }.width(28).height(28).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('打开备忘').onClick((): void => { this.openMemo() })
      }.width('100%').height('25%').padding({ left: 12, right: 8 }).backgroundColor('#F4BF35')
      Column() {
        // 直接在响应式列表中读取绑定字段，避免 Builder 值参数停留在首次空快照。
        ForEach([this.item1, this.item2, this.item3], (title: string, index: number) => {
          if (title.length > 0) {
            Column() {
              Row({ space: 8 }) {
                Rect().width(3).height(14).radius(1.5).fill('#F2C400')
                Text(title).layoutWeight(1).fontSize(14).fontColor('#E4E0D5')
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.width('100%').height(40).padding({ left: 14, right: 12 })
                .onClick((): void => { this.openMemo() })
              if (index < 2) {
                Row() {
                  Rect().width('100%').height(0.5).fill('#39311B')
                }.width('100%').height(0.5).padding({ left: 25, right: 12 })
              }
            }.width('100%').flexShrink(0)
          }
        }, (title: string, index: number): string => `${index}:${title}`)
        if (this.item1.length === 0 && this.item2.length === 0 && this.item3.length === 0) {
          Text(this.message).width('100%').padding({ left: 14, right: 12, top: 14 })
            .fontSize(13).fontColor('#AFA98D').maxLines(2)
            .onClick((): void => { this.openMemo() })
        }
      }.width('100%').height('75%').clip(true).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').backgroundColor('#211A08').clip(true)
      .onClick((): void => { this.openMemo() })
  }
}
