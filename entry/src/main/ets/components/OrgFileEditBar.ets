import { OrgFileEditView, OrgFilePlacement, OrgFileStructureChange, projectEditIdle } from '../ui/OrgFileStructurePresentation'
import { UiColor } from '../ui/Theme'
import { TaskBatchToolbar } from './TaskBatchToolbar'
import { TaskOperation } from '../ui/TaskActionPresentation'

@Component
export struct OrgFileEditBar {
  @Prop edit: OrgFileEditView = projectEditIdle()
  @Prop busy: boolean = false
  @Prop stale: boolean = false
  @Prop message: string = ''
  @Prop renaming: boolean = false
  @Prop renameValue: string = ''
  cancel: () => void = () => {}
  place: () => void = () => {}
  root: () => void = () => {}
  choose: (placement: OrgFilePlacement) => void = () => {}
  undo: () => void = () => {}
  review: () => void = () => {}
  save: () => void = () => {}
  renameValueChanged: (value: string) => void = () => {}
  confirmRename: () => void = () => {}

  @Builder
  status() {
    if (this.message || this.stale) {
      Text(this.stale ? '项目已更新。退出后可重新选择节点。' : this.message)
        .fontSize(13).fontColor(UiColor.error).width('100%')
    }
  }

  @Builder
  choices() {
    Row({ space: 8 }) {
      Text(this.edit.targetChosen ? this.edit.targetPath : '选择放置目标').fontSize(15).fontColor(UiColor.text)
        .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      Button('顶层').fontColor(UiColor.primary).backgroundColor(Color.Transparent).height(44)
        .enabled(!this.busy && !this.stale).onClick(this.root)
      Button('返回').fontColor(UiColor.secondary).backgroundColor(Color.Transparent).height(44)
        .enabled(!this.busy).onClick(this.cancel)
    }.width('100%')
    if (this.edit.targetChosen) {
      if (this.edit.target) {
        Row({ space: 4 }) {
          Button('放在前面').id('project_place_before').layoutWeight(1).height(44).enabled(!this.stale && !this.busy)
            .backgroundColor(UiColor.field).fontColor(UiColor.text).onClick((): void => { this.choose('before') })
          Button('放在后面').id('project_place_after').layoutWeight(1).height(44).enabled(!this.stale && !this.busy)
            .backgroundColor(UiColor.field).fontColor(UiColor.text).onClick((): void => { this.choose('after') })
          Button('首个子节点').id('project_place_child').layoutWeight(1).height(44).enabled(!this.stale && !this.busy)
            .backgroundColor(UiColor.field).fontColor(UiColor.text).onClick((): void => { this.choose('child') })
        }.width('100%')
      } else {
        Row({ space: 8 }) {
          Button('顶层首位').layoutWeight(1).height(44).enabled(!this.stale && !this.busy)
            .backgroundColor(UiColor.field).fontColor(UiColor.text).onClick((): void => { this.choose('first') })
          Button('顶层末位').layoutWeight(1).height(44).enabled(!this.stale && !this.busy)
            .backgroundColor(UiColor.field).fontColor(UiColor.text).onClick((): void => { this.choose('last') })
        }.width('100%')
      }
    } else {
      Text('点选文档中的章节或任务，整棵子树随节点放置。').fontSize(13).fontColor(UiColor.secondary).width('100%')
    }
  }

  @Builder
  changes() {
    Row() {
      Text(this.edit.refactoring ? `${this.edit.changes.length} 项变更` : `放置 ${this.edit.count} 个节点`)
        .fontSize(15).fontColor(UiColor.text).layoutWeight(1)
      Button('返回').fontColor(UiColor.secondary).backgroundColor(Color.Transparent).height(44)
        .enabled(!this.busy).onClick(this.cancel)
      Button(this.busy ? '正在保存' : this.edit.refactoring ? '保存全部' : '确认放置')
        .id('project_edit_save').height(44).fontColor(UiColor.surface).backgroundColor(UiColor.primary)
        .enabled(!this.busy && !this.stale && this.edit.changes.length > 0).onClick(this.save)
    }.width('100%')
    Scroll() {
      Column({ space: 8 }) {
        ForEach(this.edit.changes, (change: OrgFileStructureChange) => {
          Text(`${change.title} › ${change.parentPath} › ${change.after}`).fontSize(13).fontColor(UiColor.secondary)
            .width('100%')
        }, (change: OrgFileStructureChange) => change.id)
      }.width('100%').alignItems(HorizontalAlign.Start)
    }.width('100%').constraintSize({ maxHeight: 124 }).scrollBar(BarState.Auto)
  }

  @Builder
  refactorControls() {
    Row({ space: 3 }) {
      Text(this.edit.count ? `已选 ${this.edit.count} 条` : '重构').fontSize(15).fontColor(UiColor.text).layoutWeight(1)
      Button('退出').fontColor(UiColor.secondary).backgroundColor(Color.Transparent).height(44)
        .enabled(!this.busy).onClick(this.cancel)
      Button('放置').id('project_refactor_place').fontColor(UiColor.primary).backgroundColor(Color.Transparent).height(44)
        .enabled(!this.busy && !this.stale && this.edit.count > 0).onClick(this.place)
      Button('撤销').fontColor(UiColor.primary).backgroundColor(Color.Transparent).height(44)
        .enabled(!this.busy && !this.stale && this.edit.changes.length > 0).onClick(this.undo)
      Button('查看变更').fontColor(UiColor.primary).backgroundColor(Color.Transparent).height(44)
        .enabled(!this.busy && this.edit.changes.length > 0).onClick(this.review)
    }.width('100%')
  }

  build() {
    if (!this.edit.refactoring && this.edit.phase === 'select') {
      Column() {
        TaskBatchToolbar({ items: [
          { id: TaskOperation.Place, title: '放置', label: '在项目内放置已选节点', icon: $r('app.media.ui_place'), action: this.place }
        ], count: this.edit.count, busy: this.busy, invalid: this.stale,
          message: this.stale ? '项目已更新。退出后可重新选择节点。' : this.message, idPrefix: 'project_batch',
          retry: this.cancel, cancel: this.cancel })
      }.width('100%')
    } else {
      Column({ space: 6 }) {
        if (this.renaming) {
          Row({ space: 8 }) {
            TextInput({ text: this.renameValue, placeholder: '标题' }).id('project_rename_title').height(44)
              .layoutWeight(1).backgroundColor(UiColor.field).fontColor(UiColor.text)
              .onChange(this.renameValueChanged).onSubmit(this.confirmRename)
            Button('取消').fontColor(UiColor.secondary).backgroundColor(Color.Transparent).height(44).onClick(this.cancel)
            Button('应用').fontColor(UiColor.primary).backgroundColor(Color.Transparent).height(44)
              .enabled(!this.stale && !!this.renameValue.trim()).onClick(this.confirmRename)
          }.width('100%')
        } else if (this.edit.phase === 'target') {
          this.choices()
        } else if (this.edit.phase === 'review') {
          this.changes()
        } else {
          this.refactorControls()
        }
        this.status()
      }.width('100%').padding({ left: 14, right: 14, top: 8, bottom: 10 }).backgroundColor(UiColor.dialog)
    }
  }
}
