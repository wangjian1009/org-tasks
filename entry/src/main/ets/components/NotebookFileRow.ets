import { localizedText } from '../ui/LocalizedText'
import { SYSTEM_REPOSITORY_ID, TRASH_FILE } from '../models/SystemRepository'
import { PageNavigator } from '../services/PageNavigator'
import { CoreOrgFileMetadata, CoreTitlePart } from '../services/NativeCoreService'
import { PageParameters } from '../services/PagePath'
import { FileTargetKind, fileTargetName } from '../services/FileTargetService'
import { TaskSwipeActions } from './TaskSwipeActions'
import { TaskActionItem } from '../ui/TaskActionPresentation'
import { fileModifiedLabel, filePathLabel, fileSizeLabel, fileTaskCount } from '../ui/NotebookPresentation'
import { UiColor } from '../ui/Theme'

// 文件概要、展开详情与左滑操作共用同一个原生列表项。
@Component
export struct NotebookFileRow {
  @Prop file: CoreOrgFileMetadata
  @Prop configRepoId: string = ''
  @Prop usages: FileTargetKind[] = []
  @Prop actionsEnabled: boolean = false
  @Prop expanded: boolean = false
  toggleExpanded: () => void = () => {}
  closeSwipe: () => void = () => {}
  rename: () => void = () => {}
  remove: () => void = () => {}

  private isTrashEntry(): boolean {
    return this.configRepoId === SYSTEM_REPOSITORY_ID && this.file.path === TRASH_FILE
  }

  private title(): string {
    const text = this.file.titleParts.map((part: CoreTitlePart): string => part.text).join('').trim()
    return text || this.file.title?.trim() || filePathLabel(this.file.path)
  }

  private usageColor(kind: FileTargetKind): string {
    return kind === 'inbox' ? '#355F5A' : kind === 'someday' ? '#594A73' : '#655837'
  }

  private summaryLabel(): string {
    const labels = [this.title(), fileModifiedLabel(this.file.modifiedAt, true)]
    if (!this.isTrashEntry()) {
      for (const kind of this.usages) labels.push(fileTargetName(kind))
      if (this.file.project() !== null) labels.push(localizedText($r('app.string.text_project')))
      if (this.file.hasConflict) labels.push(localizedText($r('app.string.text_conflict')))
    }
    return labels.join('，')
  }

  private activateSummary(): void {
    if (this.isTrashEntry()) this.openFile()
    else {
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => { this.toggleExpanded() })
    }
  }

  private openFile(): void {
    try {
      if (this.isTrashEntry()) {
        PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/Trash' }); return
      }
      const resolveConflict = this.file.project() === null && this.file.hasConflict
      const params: PageParameters = { repoId: resolveConflict ? this.configRepoId : this.file.repoId, path: this.file.path }
      PageNavigator.shared.pushPage(this.getUIContext(), {
        url: resolveConflict ? 'pages/ConflictFile' : 'pages/OrgFileDetail', params
      })
    } catch (_) {
      // 页面退出或路由失效时忽略此次导航。
    }
  }

  private actions(): TaskActionItem[] {
    const items: TaskActionItem[] = [
      { id: 'edit', title: localizedText($r('app.string.text_edit')), label: localizedText($r('app.string.text_edit_file')), icon: $r('app.media.ui_link_edit'),
        action: (): void => { this.closeSwipe(); this.openFile() } }
    ]
    if (this.configRepoId !== SYSTEM_REPOSITORY_ID) {
      items.push({ id: 'rename', title: localizedText($r('app.string.text_change_name')), label: localizedText($r('app.string.text_change_file_name')), icon: $r('app.media.ui_note_action'),
        action: (): void => { this.closeSwipe(); this.rename() } })
    }
    items.push({ id: 'delete', title: localizedText($r('app.string.text_delete')), label: localizedText($r('app.string.text_delete_file')), icon: $r('app.media.ui_delete'), style: 'danger',
      action: (): void => { this.closeSwipe(); this.remove() } })
    return items
  }

  @Builder
  swipeMenu() {
    TaskSwipeActions({ items: this.actions(), idPrefix: 'notebook_file_swipe' })
  }

  @Builder
  badge(label: string, background: string, foreground: string = '#E8E8E8') {
    Text(label).fontSize(11).fontColor(foreground).maxLines(1)
      .padding({ left: 4, right: 4, top: 2, bottom: 2 })
      .backgroundColor(background).borderRadius(10)
  }

  @Builder
  summary() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 6 }) {
        Text(this.title()).fontSize(16).fontColor(UiColor.text).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1).constraintSize({ minWidth: 0 })
        if (!this.isTrashEntry() && (this.usages.length > 0 || this.file.project() !== null || this.file.hasConflict)) {
          Row({ space: 4 }) {
            ForEach(this.usages, (kind: FileTargetKind) => {
              this.badge(fileTargetName(kind), this.usageColor(kind))
            }, (kind: FileTargetKind) => kind)
            if (this.file.project() !== null) this.badge(localizedText($r('app.string.text_project')), '#3A536A')
            if (this.file.hasConflict) this.badge(localizedText($r('app.string.text_conflict')), UiColor.conflictBadge, UiColor.error)
          }.flexShrink(0)
        }
        Text(fileModifiedLabel(this.file.modifiedAt, true)).fontSize(12).fontColor(UiColor.secondary)
          .maxLines(1).flexShrink(0)
        if (!this.isTrashEntry()) {
          Image($r('app.media.ui_down')).width(16).height(16).flexShrink(0)
            .fillColor(this.expanded ? UiColor.text : UiColor.secondary)
            .rotate({ angle: this.expanded ? 180 : 0 })
            .accessibilityLevel('no')
        }
      }.width('100%').alignItems(VerticalAlign.Center).constraintSize({ minHeight: 32 })
    }.width('100%').constraintSize({ minHeight: 44 }).padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .backgroundColor(Color.Transparent).borderRadius(8)
      .accessibilityText(this.summaryLabel())
      .accessibilityDescription(this.isTrashEntry() ? localizedText($r('app.string.text_open_scrap')) : this.expanded ? localizedText($r('app.string.text_close_file_details')) : localizedText($r('app.string.text_expand_file_details')))
      .onClick((): void => { this.activateSummary() })
  }

  @Builder
  details() {
    Column({ space: 4 }) {
      Text(filePathLabel(this.file.path)).fontSize(13).fontColor(UiColor.text)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      Text(localizedText($r('app.string.text_tasks'), String(fileTaskCount(this.file)), String(fileSizeLabel(this.file.byteLength))))
        .fontSize(12).fontColor(UiColor.secondary)
    }.width('100%').padding({ left: 8, right: 8, bottom: 12 }).alignItems(HorizontalAlign.Start)
      .transition(TransitionEffect.translate({ y: -8 }).combine(TransitionEffect.OPACITY))
  }

  build() {
    ListItem() {
      Column() {
        this.summary()
        if (this.expanded) this.details()
      }.width('100%').backgroundColor(this.expanded ? UiColor.taskCard : Color.Transparent)
        .borderRadius(12).clip(true)
    }.swipeAction(this.actionsEnabled ? {
      end: { builder: this.swipeMenu }, edgeEffect: SwipeEdgeEffect.None
    } : {})
  }
}
