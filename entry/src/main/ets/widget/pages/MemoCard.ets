/** 桌面备忘服务卡片，数据由 MemoFormExtension 写入 FormBindingData。 */
@Entry
@Component
struct MemoCard {
  @LocalStorageProp('memoCardTitle') cardTitle: string = '全部备忘'
  @LocalStorageProp('memoCardItem1') item1: string = ''
  @LocalStorageProp('memoCardItem2') item2: string = ''
  @LocalStorageProp('memoCardItem3') item3: string = ''

  private openMemo(): void {
    postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { page: 'memo' } })
  }

  @Builder
  private memoRow(title: string) {
    if (title.length > 0) {
      Row({ space: 10 }) {
        Blank().width(4).height(20).backgroundColor('#F2C400').borderRadius(2)
        Text(title).layoutWeight(1).fontSize(16).fontColor('#E4E0D5')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank().width(12)
      }.width('100%').height(36).padding({ left: 18, right: 12 })
        .onClick((): void => { this.openMemo() })
    }
  }

  build() {
    Column() {
      Row() {
        Text(this.cardTitle).layoutWeight(1).fontSize(20).fontWeight(FontWeight.Medium)
          .fontColor('#FFF8DC').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Button({ type: ButtonType.Circle }) {
          Text('+').fontSize(32).fontColor('#FFF8DC').fontWeight(FontWeight.Lighter)
        }.width(40).height(40).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('打开备忘').onClick((): void => { this.openMemo() })
      }.width('100%').height(58).padding({ left: 18, right: 12 }).backgroundColor('#F4BF35')
      Column({ space: 1 }) {
        this.memoRow(this.item1)
        this.memoRow(this.item2)
        this.memoRow(this.item3)
        if (this.item1.length === 0 && this.item2.length === 0 && this.item3.length === 0) {
          Text('暂无备忘').width('100%').height(48).padding({ left: 22, top: 12 })
            .fontSize(15).fontColor('#AFA98D').onClick((): void => { this.openMemo() })
        }
      }.width('100%').layoutWeight(1).padding({ top: 10, bottom: 10 })
    }.width('100%').height('100%').backgroundColor('#211A08').clip(true)
      .onClick((): void => { this.openMemo() })
  }
}
