import { CoreRefileTarget } from '../../services/NativeCoreService'
import { MoveTargetHistoryService } from '../../services/MoveTargetHistoryService'
import { RefileSection, recentRefileSections, refileTargetKey, refileTargetTitle } from '../../ui/MoveToTargetPresentation'
import { UiColor, UiSize } from '../../ui/Theme'
import { TitleText } from '../TitleText'

@Component
export struct MoveToTarget {
  @Prop @Watch('sectionsChanged') sections: RefileSection[] = []
  @Prop @Watch('resetSelection') selectionKey: string = ''
  @Prop loading: boolean = false
  @Prop busy: boolean = false
  @Prop message: string = ''
  @State selectedTarget: CoreRefileTarget | undefined = undefined
  @State orderedSections: RefileSection[] = []
  @State historyMessage: string = ''
  private recent: string[] = []
  private historyReady: boolean = false
  private disposed: boolean = false
  private interactionStarted: boolean = false
  choose: (target: CoreRefileTarget) => void = () => {}
  retry: () => void = () => {}

  async aboutToAppear() {
    this.disposed = false
    this.sectionsChanged()
    await this.loadHistory()
  }

  aboutToDisappear() { this.disposed = true }

  async loadHistory() {
    try {
      const recent = await MoveTargetHistoryService.load(this.getUIContext().getHostContext()!)
      if (this.disposed) return
      if (!this.interactionStarted) this.recent = recent
      this.historyReady = true
      this.historyMessage = ''
      this.sectionsChanged()
    } catch (_) {
      if (!this.disposed) this.historyMessage = '最近选择读取失败，点击重试'
    }
  }

  resetSelection() { this.selectedTarget = undefined; this.sectionsChanged() }

  sectionsChanged() {
    this.orderedSections = recentRefileSections(this.sections, this.recent)
    const targets = this.orderedSections.flatMap((section: RefileSection): CoreRefileTarget[] => section.targets)
    if (this.selectedTarget) {
      const key = refileTargetKey(this.selectedTarget)
      this.selectedTarget = targets.find((target: CoreRefileTarget): boolean => refileTargetKey(target) === key)
    }
    if (!this.selectedTarget && this.historyReady) {
      this.selectedTarget = targets.find((target: CoreRefileTarget): boolean => this.recent.includes(refileTargetKey(target)))
    }
  }

  isSelected(target: CoreRefileTarget): boolean {
    return this.selectedTarget !== undefined && JSON.stringify(this.selectedTarget) === JSON.stringify(target)
  }

  select(target: CoreRefileTarget) {
    if (this.busy || this.loading) return
    this.interactionStarted = true
    this.selectedTarget = target
    // 当前面板不因点击重排；下一次打开时再按已保存的选择顺序排序。
    MoveTargetHistoryService.remember(this.getUIContext().getHostContext()!, refileTargetKey(target))
      .then((): void => { if (!this.disposed) this.historyMessage = '' })
      .catch((): void => { if (!this.disposed) this.historyMessage = '最近选择保存失败，请重新选择' })
  }

  move(target: CoreRefileTarget) {
    if (this.busy || this.loading || !this.isSelected(target)) return
    this.choose(target)
  }

  @Builder
  sectionHeading(section: RefileSection) {
    Row({ space: 8 }) {
      Image(section.kind === 'project' ? $r('app.media.ui_folder') : $r('app.media.ui_category_muted'))
        .width(16).height(16).fillColor(UiColor.secondary).accessibilityLevel('no')
      Text(section.name || '未分类').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiColor.secondary)
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 12, right: 12, top: 28, bottom: 8 })
      .accessibilityText(`${section.kind === 'project' ? '项目' : '分类'}，${section.name || '未分类'}`)
  }

  @Builder
  targetRow(target: CoreRefileTarget) {
    Row({ space: 8 }) {
      TitleText({ text: refileTargetTitle(target), parts: target.titleParts, showCounts: false, openLinks: false,
        textSize: UiSize.taskFont, lineLimit: 1, weight: this.isSelected(target) ? FontWeight.Medium : FontWeight.Normal,
        activate: (): void => this.select(target) }).layoutWeight(1).constraintSize({ minWidth: 0 })
      if (this.isSelected(target)) {
        Button('移动').id('move_to_target').width(58).height(32).padding(0).borderRadius(10)
          .backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary).fontSize(UiSize.taskFont).enabled(!this.busy && !this.loading)
          .accessibilityText(`移动到${refileTargetTitle(target)}`)
          .onClick((): void => this.move(target))
      }
    }.width('100%').height(UiSize.taskRow).padding({ left: 36, right: 10, top: 4, bottom: 4 })
      .backgroundColor(this.isSelected(target) ? '#3F514A' : Color.Transparent)
      .border({ width: this.isSelected(target) ? 1 : 0, color: UiColor.primary }).borderRadius(10)
      .accessibilityText(`${refileTargetTitle(target)}${this.isSelected(target) ? '，已选中' : '，点击选择'}`)
      .enabled(!this.busy && !this.loading).onClick((): void => this.select(target))
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Image($r('app.media.ui_move_to')).width(24).height(24).accessibilityLevel('no')
        Text('移动到').fontSize(20).fontColor(UiColor.text).fontWeight(FontWeight.Medium)
      }.width('100%').height(48).padding({ left: 16, right: 16 })
      Divider().color(UiColor.outline).margin({ left: 12, right: 12 })
      if (this.historyMessage) {
        Text(this.historyMessage).fontSize(13).fontColor(UiColor.error).padding(12).width('100%')
          .onClick((): void => { this.loadHistory() })
      }
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
          Text('创建项目，或在目标标题上添加 REFILE 标签后重试。').fontSize(13).fontColor(UiColor.secondary)
        }.width('100%').height(80).justifyContent(FlexAlign.Center)
      } else {
        List({ space: 0 }) {
          ForEach(this.orderedSections, (section: RefileSection) => {
            ListItemGroup({ header: this.sectionHeading(section) }) {
              ForEach(section.targets, (target: CoreRefileTarget) => {
                ListItem() { this.targetRow(target) }
              }, (target: CoreRefileTarget) => JSON.stringify(target))
            }
          }, (section: RefileSection) => section.key)
        }.width('100%').layoutWeight(1).padding({ left: 12, right: 12, bottom: 16 })
          .edgeEffect(EdgeEffect.None)
          .nestedScroll({ scrollForward: NestedScrollMode.SELF_ONLY, scrollBackward: NestedScrollMode.SELF_ONLY })
      }
    }.width('100%').height('100%').backgroundColor('#363A38')
      .padding({ bottom: 8 })
  }
}
