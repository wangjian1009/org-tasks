import { CoreRefileTarget } from '../services/NativeCoreService'
import { RefileSection } from '../ui/InboxPresentation'
import { UiColor, UiSize } from '../ui/Theme'
import { TitleText } from './TitleText'

@Component
export struct InboxTargetPopup {
  @Prop @Watch('sectionsChanged') sections: RefileSection[] = []
  @Prop @Watch('resetSelection') selectionKey: string = ''
  @Prop loading: boolean = false
  @Prop busy: boolean = false
  @Prop message: string = ''
  @State selectedTarget: CoreRefileTarget | undefined = undefined
  @State activeTabIndex: number = 0
  private tabsController: TabsController = new TabsController()
  choose: (target: CoreRefileTarget) => void = () => {}
  retry: () => void = () => {}

  resetSelection() { this.selectedTarget = undefined }

  sectionsChanged() {
    if (this.selectedTarget && !this.sections.some((section: RefileSection) =>
      section.targets.some((target: CoreRefileTarget) => this.isSelected(target)))) this.resetSelection()
    if (this.activeTabIndex >= this.sections.length) {
      this.activeTabIndex = 0
      if (this.sections.length > 0) this.tabsController.changeIndex(0)
    }
  }

  isSelected(target: CoreRefileTarget): boolean {
    return this.selectedTarget !== undefined && JSON.stringify(this.selectedTarget) === JSON.stringify(target)
  }

  select(target: CoreRefileTarget) {
    if (!this.busy && !this.loading) this.selectedTarget = target
  }

  move(target: CoreRefileTarget) {
    if (this.busy || this.loading || !this.isSelected(target)) return
    this.choose(target)
  }

  @Builder
  categoryTab(section: RefileSection, index: number) {
    Column({ space: 4 }) {
      Text(section.category || '未分类').fontSize(UiSize.taskFont).fontWeight(this.activeTabIndex === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.activeTabIndex === index ? UiColor.primary : UiColor.secondary)
        .maxLines(1).constraintSize({ maxWidth: 160 }).textOverflow({ overflow: TextOverflow.Ellipsis })
      Row().height(2).width(28).backgroundColor(this.activeTabIndex === index ? UiColor.primary : Color.Transparent).borderRadius(1)
    }.height(40).padding({ left: 14, right: 14, top: 6 }).justifyContent(FlexAlign.Center)
      .accessibilityText(`${section.category || '未分类'}${this.activeTabIndex === index ? '，已选择' : ''}`)
  }

  @Builder
  targetRow(target: CoreRefileTarget) {
    Row({ space: 8 }) {
      TitleText({ text: target.headingPath[target.headingPath.length - 1] || '',
        textSize: UiSize.taskFont, lineLimit: 1, weight: this.isSelected(target) ? FontWeight.Medium : FontWeight.Normal,
        activate: (): void => this.select(target) }).layoutWeight(1).constraintSize({ minWidth: 0 })
      if (this.isSelected(target)) {
        Button('移动').id('inbox_move_target').width(58).height(32).padding(0).borderRadius(10)
          .backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary).fontSize(UiSize.taskFont).enabled(!this.busy && !this.loading)
          .accessibilityText(`移动到${target.headingPath[target.headingPath.length - 1] || ''}`)
          .onClick((): void => this.move(target))
      }
    }.width('100%').height(UiSize.taskRow).padding({ left: 12, right: 10, top: 4, bottom: 4 })
      .backgroundColor(this.isSelected(target) ? '#3F514A' : Color.Transparent)
      .border({ width: this.isSelected(target) ? 1 : 0, color: UiColor.primary }).borderRadius(10)
      .accessibilityText(`${target.headingPath[target.headingPath.length - 1] || ''}${this.isSelected(target) ? '，已选中' : '，点击选择'}`)
      .enabled(!this.busy && !this.loading).onClick((): void => this.select(target))
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Image($r('app.media.ui_move_to')).width(24).height(24).accessibilityLevel('no')
        Text('移动到').fontSize(UiSize.taskFont).fontColor(UiColor.text).fontWeight(FontWeight.Medium)
      }.width('100%').height(48).padding({ left: 16, right: 16 })
      Divider().color(UiColor.outline).margin({ left: 12, right: 12 })
      if (this.busy) {
        Text('正在保存…').fontSize(14).fontColor(UiColor.secondary).padding({ left: 12, right: 12 }).height(40).width('100%')
      }
      if (this.message) {
        Text(this.message).fontSize(14).fontColor(UiColor.error).lineHeight(20).maxLines(3).padding(12).height(84).width('100%')
        Button('刷新后重试').height(40).onClick((): void => this.retry()).enabled(!this.busy)
      }
      if (this.loading) {
        Row({ space: 8 }) {
          LoadingProgress().width(24).height(24)
          Text('正在读取任务目标').fontSize(14).fontColor(UiColor.secondary)
        }.width('100%').height(64).justifyContent(FlexAlign.Center)
      } else if (this.sections.length === 0) {
        Column({ space: 8 }) {
          Text('暂无任务目标').fontSize(16).fontColor(UiColor.text)
          Text('在目标标题上添加 REFILE 标签后重试。').fontSize(13).fontColor(UiColor.secondary)
        }.width('100%').height(80).justifyContent(FlexAlign.Center)
      } else {
        Tabs({ barPosition: BarPosition.Start, controller: this.tabsController, index: this.activeTabIndex }) {
          ForEach(this.sections, (section: RefileSection, index: number) => {
            TabContent() {
              List({ space: 0 }) {
                ForEach(section.targets, (target: CoreRefileTarget) => {
                  ListItem() { this.targetRow(target) }
                }, (target: CoreRefileTarget) => JSON.stringify(target))
              }.width('100%').height('100%').padding({ left: 12, right: 12, top: 4, bottom: 4 })
                .edgeEffect(EdgeEffect.None)
                .nestedScroll({ scrollForward: NestedScrollMode.SELF_ONLY, scrollBackward: NestedScrollMode.SELF_ONLY })
            }.tabBar(this.categoryTab(section, index))
          }, (section: RefileSection) => JSON.stringify(section))
        }.width('100%').layoutWeight(1).barHeight(40).barMode(BarMode.Scrollable)
          .scrollable(!this.busy).enabled(!this.busy).onChange((index: number): void => {
            if (this.activeTabIndex !== index) { this.activeTabIndex = index; this.resetSelection() }
          })
      }
    }.width('100%').height('100%').backgroundColor('#363A38')
      .borderRadius(16).border({ width: 1, color: '#555E57' }).clip(true).padding({ bottom: 8 })
  }
}
