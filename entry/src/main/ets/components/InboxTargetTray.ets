import { CoreRefileTarget } from '../services/NativeCoreService'
import { RefileSection } from '../ui/InboxPresentation'
import { UiColor } from '../ui/Theme'
import { TitleText } from './TitleText'

@Component
export struct InboxTargetTray {
  @Prop sections: RefileSection[] = []
  @Prop loading: boolean = false
  @Prop busy: boolean = false
  @Prop message: string = ''
  choose: (target: CoreRefileTarget) => void = () => {}
  memo: () => void = () => {}
  remove: () => void = () => {}
  retry: () => void = () => {}
  expand: () => void = () => {}
  collapse: () => void = () => {}

  @Builder
  category(section: RefileSection) {
    Text(section.category || '未分类').width('100%').height(32).fontSize(13).fontColor('#9EB5AA')
      .padding({ left: 20, right: 20 }).backgroundColor('#303532')
  }

  build() {
    Column() {
      Row() {
        Row().width(44).height(4).backgroundColor('#858B84').borderRadius(2)
      }.width('100%').height(28).justifyContent(FlexAlign.Center)
        .accessibilityText('向上展开或向下收起任务目标托盘').enabled(!this.busy)
        .onClick((): void => this.expand())
        .gesture(PanGesture({ direction: PanDirection.Vertical }).onActionEnd((event: GestureEvent): void => {
          if (event.offsetY > 32) this.collapse()
          else if (event.offsetY < -20) this.expand()
        }))
      Row({ space: 12 }) {
        Text('选择任务目标').fontSize(18).fontColor(UiColor.text).fontWeight(FontWeight.Medium).layoutWeight(1)
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ui_convert_memo')).width(24).height(24)
        }.height(44).width(52).padding(0).borderRadius(10).backgroundColor('#454B47')
          .accessibilityText('转换为备忘').enabled(!this.busy)
          .onClick((): void => this.memo())
          .gesture(LongPressGesture().onAction((): void => { this.getUIContext().getPromptAction().showToast({ message: '转换为备忘' }) }))
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ui_delete_record')).width(24).height(24)
        }.height(44).width(52).padding(0).borderRadius(10).backgroundColor(Color.Transparent)
          .accessibilityText('删除').enabled(!this.busy)
          .onClick((): void => this.remove())
          .gesture(LongPressGesture().onAction((): void => { this.getUIContext().getPromptAction().showToast({ message: '删除' }) }))
      }.width('100%').height(60).padding({ left: 20, right: 20 })
      Divider().color(UiColor.outline).margin({ left: 20, right: 20 })
      if (this.busy) {
        Text('正在保存…').fontSize(14).fontColor(UiColor.secondary).padding(12).width('100%')
      }
      if (this.message) {
        Text(this.message).fontSize(14).fontColor(UiColor.error).padding(12).width('100%')
        Button('刷新后重试').height(40).onClick((): void => this.retry()).enabled(!this.busy)
      }
      if (this.loading) {
        Row({ space: 8 }) {
          LoadingProgress().width(24).height(24)
          Text('正在读取任务目标').fontSize(14).fontColor(UiColor.secondary)
        }.layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.sections.length === 0) {
        Column({ space: 8 }) {
          Text('暂无任务目标').fontSize(16).fontColor(UiColor.text)
          Text('在目标标题上添加 REFILE 标签后重试。').fontSize(13).fontColor(UiColor.secondary)
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.sections, (section: RefileSection) => {
            ListItemGroup({ header: this.category(section) }) {
              ForEach(section.targets, (target: CoreRefileTarget) => {
                ListItem() {
                  Column() {
                    TitleText({ text: target.headingPath[target.headingPath.length - 1] || '',
                      textSize: 16, weight: FontWeight.Medium, activate: (): void => this.choose(target) })
                      .width('100%').padding({ left: 32, right: 20, top: 12, bottom: 12 })
                    Divider().color(UiColor.outline).margin({ left: 32, right: 20 })
                  }.width('100%').constraintSize({ minHeight: 48 }).enabled(!this.busy)
                    .onClick((): void => this.choose(target))
                }
              }, (target: CoreRefileTarget) => JSON.stringify(target))
            }
          }, (section: RefileSection) => section.category)
        }.width('100%').layoutWeight(1).edgeEffect(EdgeEffect.None)
          .nestedScroll({ scrollForward: NestedScrollMode.SELF_ONLY, scrollBackward: NestedScrollMode.SELF_ONLY })
      }
    }.width('100%').height('100%').backgroundColor('#363A38')
      .borderRadius({ topLeft: 24, topRight: 24 }).clip(true).padding({ bottom: 12 })
  }
}
