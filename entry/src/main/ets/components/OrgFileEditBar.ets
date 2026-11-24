import { OrgFileEditView, OrgFilePlacement, projectEditIdle } from '../ui/OrgFileStructurePresentation'
import { UiColor } from '../ui/Theme'
import { ChoiceChip } from './controls/ChoiceChip'

@Component
export struct OrgFileEditBar {
  @Prop edit: OrgFileEditView = projectEditIdle()
  @Link placementOpen: boolean
  @Prop busy: boolean = false
  @Prop stale: boolean = false
  @Prop message: string = ''
  cancel: () => void = () => {}
  root: () => void = () => {}
  choose: (placement: OrgFilePlacement) => void = () => {}

  @Builder
  status() {
    if (this.message || this.stale) {
      Text(this.stale ? '项目已更新。退出后可重新选择节点。' : this.message)
        .fontSize(13).fontColor(UiColor.error).width('100%')
    }
  }

  @Builder
  placementChip(placement: OrgFilePlacement, label: string) {
    ChoiceChip({ label, controlId: `project_place_${placement}`, chipWidth: 88,
      disabled: this.busy || this.stale, choose: (): void => { this.choose(placement) } })
  }

  @Builder
  placementPopup() {
    Row({ space: 6 }) {
      if (this.edit.target) {
        this.placementChip('before', '放在前面')
        this.placementChip('after', '放在后面')
        this.placementChip('child', '首个子节点')
      } else {
        this.placementChip('first', '顶层首位')
        this.placementChip('last', '顶层末位')
      }
    }.padding(8).backgroundColor(UiColor.menu).borderRadius(10)
  }

  @Builder
  choices() {
    Row({ space: 8 }) {
      if (this.edit.targetChosen) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 4 }) {
            Text(this.edit.targetPath).fontSize(15).fontColor(UiColor.primary)
              .constraintSize({ minWidth: 0 }).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            Image($r('app.media.ui_more_horizontal')).width(16).height(16).fillColor(UiColor.primary)
              .accessibilityLevel('no')
          }.constraintSize({ maxWidth: '100%' })
        }.layoutWeight(1).constraintSize({ minWidth: 0, minHeight: 44 }).padding(0).align(Alignment.Start)
          .backgroundColor(Color.Transparent).enabled(!this.busy && !this.stale)
          .accessibilityText(`选择放置关系，${this.edit.targetPath}`)
          .onClick((): void => { this.placementOpen = true })
      } else {
        Text('选择放置目标').fontSize(15).fontColor(UiColor.text).layoutWeight(1)
      }
      Button('顶层').fontColor(UiColor.primary).backgroundColor(Color.Transparent).height(44)
        .enabled(!this.busy && !this.stale).onClick(this.root)
      Button('返回').fontColor(UiColor.secondary).backgroundColor(Color.Transparent).height(44)
        .enabled(!this.busy).onClick(this.cancel)
    }.width('100%')
      .bindPopup(this.placementOpen && this.edit.targetChosen && !this.busy && !this.stale, {
        builder: this.placementPopup, placement: Placement.TopLeft, targetSpace: 6, enableArrow: false,
        radius: 10, popupColor: UiColor.menu, backgroundBlurStyle: BlurStyle.NONE,
        mask: { color: Color.Transparent }, focusable: true, autoCancel: true,
        onStateChange: (event): void => { if (!event.isVisible) this.placementOpen = false }
      })
    if (!this.edit.targetChosen) {
      Text('点选文档中的章节或任务，整棵子树随节点放置。').fontSize(13).fontColor(UiColor.secondary).width('100%')
    }
  }

  @Builder
  moveControls() {
    Row({ space: 8 }) {
      Text('点标题移动，长按手柄排序').fontSize(13).fontColor(UiColor.secondary).layoutWeight(1)
      Button('退出').fontColor(UiColor.secondary).backgroundColor(Color.Transparent).height(44)
        .enabled(!this.busy).onClick(this.cancel)
    }.width('100%')
  }

  build() {
    Column({ space: 6 }) {
      if (this.busy) {
        Text('正在移动').fontSize(13).fontColor(UiColor.secondary).width('100%').height(44)
      } else if (this.edit.phase === 'target') {
        this.choices()
      } else {
        this.moveControls()
      }
      this.status()
    }.width('100%').padding({ left: 14, right: 14, top: 8, bottom: 10 }).backgroundColor(UiColor.dialog)
  }
}
