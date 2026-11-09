import { CoreMergeChange, CoreMergeChangeState, CoreMergeResolution } from '../services/NativeCoreService'
import { MergeDiffLine, mergeDiffText, mergeLineDiff } from '../ui/MergeDiff'
import { UiColor } from '../ui/Theme'

@Component
export struct MergeTaskCard {
  @Prop change: CoreMergeChange = { id: '', path: '', kind: 'modified', preamble: false,
    localChange: 'unmatched', remoteChange: 'unmatched', local: null, remote: null, resolution: null }
  @Prop choice: string = ''
  onChoose: (choice: CoreMergeResolution) => void = () => {}
  @State expanded: boolean = false
  @State side: number = 0
  @State remoteLines: MergeDiffLine[] = []
  @State localLines: MergeDiffLine[] = []
  private swiper: SwiperController = new SwiperController()

  aboutToAppear() {
    const lines = mergeLineDiff(this.change.remote?.source || '', this.change.local?.source || '')
    this.remoteLines = lines.filter((line: MergeDiffLine) => line.kind !== 'added')
    this.localLines = lines.filter((line: MergeDiffLine) => line.kind !== 'removed')
  }

  kindLabel(): string {
    if (this.change.preamble) return '文件前言'
    return this.change.kind === 'added' ? '新增' : this.change.kind === 'deleted' ? '删除' : '修改'
  }

  kindColor(): string {
    return this.change.kind === 'added' ? UiColor.done : this.change.kind === 'deleted' ? UiColor.error : UiColor.primary
  }

  stateLabel(side: string, state: CoreMergeChangeState, exists: boolean): string {
    switch (state) {
      case 'added': return `${side}新增`
      case 'deleted': return `${side}已删除`
      case 'modified': return `${side}已修改`
      case 'unchanged': return `${side}未改`
      default: return `${side}${exists ? '存在' : '不存在'}`
    }
  }

  choiceLabel(): string {
    return this.choice === CoreMergeResolution.Local ? '已采用本地' : this.choice === CoreMergeResolution.Remote ? '已采用远端' : '待决定'
  }

  kindIcon(): Resource {
    if (this.change.preamble) return $r('app.media.ui_body')
    return this.change.kind === 'added' ? $r('app.media.ui_add') : this.change.kind === 'deleted' ? $r('app.media.ui_close') : $r('app.media.ui_edit')
  }

  stateIcon(remote: boolean): Resource {
    return remote ? $r('app.media.ui_cloud') : $r('app.media.ui_edit')
  }

  decisionIcon(choice: CoreMergeResolution): Resource {
    if (choice === CoreMergeResolution.Local) return this.choice === choice ? $r('app.media.ui_done_selected') : $r('app.media.ui_done')
    return this.choice === choice ? $r('app.media.ui_close_selected') : $r('app.media.ui_close')
  }

  emptyLabel(remote: boolean): string {
    const version = remote ? this.change.remote : this.change.local
    if (version) return '（空内容）'
    const state = remote ? this.change.remoteChange : this.change.localChange
    return `${remote ? '远端' : '本地'}${state === 'deleted' ? '已删除此任务' : '无此任务'}`
  }

  showSide(index: number) {
    this.side = index
    this.swiper.changeIndex(index)
  }

  @Builder
  versionTab(label: string, index: number) {
    Row({ space: 6 }) {
      Image(index === 0 ? $r('app.media.ui_cloud') : $r('app.media.ui_edit')).width(16).height(16)
      Text(label).fontSize(13).fontColor(this.side === index ? UiColor.primary : UiColor.secondary)
    }.height(36).layoutWeight(1).borderRadius(6).justifyContent(FlexAlign.Center)
      .backgroundColor(this.side === index ? UiColor.selected : Color.Transparent)
      .accessibilityText(`${label}${this.side === index ? '，已选中' : ''}`)
      .onClick((): void => { this.showSide(index) })
  }

  @Builder
  sourceLine(line: MergeDiffLine, remote: boolean) {
    Column() {
      Row({ space: 0 }) {
        Text(`${remote ? line.localLine : line.remoteLine}`).width(36).textAlign(TextAlign.End)
          .fontSize(11).fontFamily('monospace').fontColor(UiColor.secondary).padding({ right: 8 })
        Text(mergeDiffText(line) || ' ').fontSize(13).fontFamily('monospace').lineHeight(20).layoutWeight(1)
          .fontColor(line.kind === 'removed' ? '#FFB4C2' : line.kind === 'added' ? '#A5E6B2' : UiColor.text)
          .copyOption(CopyOptions.LocalDevice)
      }.width('100%').constraintSize({ minHeight: 28 }).padding({ top: 4, bottom: 4 })
      if (!line.text.endsWith('\n')) {
        Text('\\ 文件末尾无换行').width('100%').fontSize(11).fontColor(UiColor.secondary).padding({ left: 36 }).height(22)
      }
    }.width('100%').backgroundColor(line.kind === 'removed' ? '#492F35' : line.kind === 'added' ? '#293F31' : Color.Transparent)
  }

  @Builder
  versionPane(lines: MergeDiffLine[], remote: boolean) {
    if (lines.length > 0) {
      List() {
          ForEach(lines, (line: MergeDiffLine) => {
            ListItem() { this.sourceLine(line, remote) }
          }, (line: MergeDiffLine) => `${line.kind}:${line.localLine}:${line.remoteLine}`)
        }.width('100%').height('100%')
          .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    } else {
      Column() {
        Text(this.emptyLabel(remote)).fontSize(14).fontColor(UiColor.secondary).textAlign(TextAlign.Center).padding(20)
      }.width('100%').height('100%').justifyContent(FlexAlign.Center)
    }
  }

  @Builder
  decisionButton(label: string, choice: CoreMergeResolution) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 4 }) {
        Image(this.decisionIcon(choice)).width(14).height(14)
        Text(label).fontSize(12).fontColor(this.choice === choice ? UiColor.onPrimary : UiColor.onSelected)
      }.justifyContent(FlexAlign.Center)
    }.width(86).height(44).padding(0)
      .backgroundColor(this.choice === choice ? UiColor.primary : Color.Transparent)
      .border({ width: 1, color: this.choice === choice ? UiColor.primary : UiColor.outline, radius: 8 })
      .accessibilityText(`${label}${this.choice === choice ? '，已选择' : ''}`)
      .onClick((): void => { this.onChoose(choice) })
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Row({ space: 4 }) {
          Image(this.kindIcon()).width(16).height(16)
          Text(this.kindLabel()).fontSize(12).fontColor(this.kindColor())
        }.padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(4).backgroundColor(UiColor.surface)
        Text(this.change.preamble ? '文件内容' : this.change.local?.title || this.change.remote?.title || '任务')
          .fontSize(this.change.preamble ? 14 : 16).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
          .layoutWeight(1).maxLines(this.expanded ? 6 : 2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Image(this.expanded ? $r('app.media.ui_up') : $r('app.media.ui_down')).width(18).height(18)
      }.width('100%').constraintSize({ minHeight: 32 })
        .accessibilityText(`${this.expanded ? '收起' : '展开'}${this.change.preamble ? '文件前言' : '任务'}比较，${this.choiceLabel()}`)
        .onClick((): void => { this.expanded = !this.expanded })
      Row({ space: 8 }) {
        Column({ space: 4 }) {
          Row({ space: 4 }) {
            Image(this.stateIcon(false)).width(14).height(14)
            Text(this.stateLabel('本地', this.change.localChange, this.change.local !== null)).fontSize(12).fontColor(UiColor.secondary)
          }.width('100%')
          Row({ space: 4 }) {
            Image(this.stateIcon(true)).width(14).height(14)
            Text(this.stateLabel('远端', this.change.remoteChange, this.change.remote !== null)).fontSize(12).fontColor(UiColor.secondary)
          }.width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          .onClick((): void => { this.expanded = !this.expanded })
        this.decisionButton('采用本地', CoreMergeResolution.Local)
        this.decisionButton('采用远端', CoreMergeResolution.Remote)
      }.width('100%')
      if (this.expanded) {
        Column({ space: 8 }) {
          Row({ space: 6 }) {
            this.versionTab('远端备份', 0)
            this.versionTab('本地当前', 1)
          }.width('100%')
          Swiper(this.swiper) {
            this.versionPane(this.remoteLines, true)
            this.versionPane(this.localLines, false)
          }.width('100%').height(320).index(this.side).loop(false).indicator(false)
            .onChange((index: number): void => { this.side = index })
        }.width('100%')
      }
    }.width('100%').padding(12).borderRadius(10).backgroundColor(UiColor.container)
  }
}
