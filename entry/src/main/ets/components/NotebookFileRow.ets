import { LengthMetrics } from '@kit.ArkUI'
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

  private activateSummary(): void {
    if (this.isTrashEntry()) this.openFile()
    else this.toggleExpanded()
  }

  openFile(editHeader: boolean = false) {
    try {
      if (this.isTrashEntry()) {
        PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/Trash' }); return
      }
      const resolveConflict = !editHeader && this.file.project() === null && this.file.hasConflict
      const params: PageParameters = editHeader
        ? { repoId: this.file.repoId, path: this.file.path, editHeader: true }
        : { repoId: resolveConflict ? this.configRepoId : this.file.repoId, path: this.file.path }
      PageNavigator.shared.pushPage(this.getUIContext(), {
        url: resolveConflict ? 'pages/ConflictFile' : 'pages/OrgFileDetail', params
      })
    } catch (_) {
      // 页面退出或路由失效时忽略此次导航。
    }
  }

  private actions(): TaskActionItem[] {
    return [
      { id: 'edit', title: '编辑', label: '编辑文件', icon: $r('app.media.ui_link_edit'),
        action: (): void => { this.closeSwipe(); this.openFile(true) } },
      { id: 'rename', title: '改名', label: '改文件名', icon: $r('app.media.ui_note_action'),
        action: (): void => { this.closeSwipe(); this.rename() } },
      { id: 'delete', title: '删除', label: '删除文件', icon: $r('app.media.ui_delete'), style: 'danger',
        action: (): void => { this.closeSwipe(); this.remove() } }
    ]
  }

  @Builder
  swipeMenu() {
    TaskSwipeActions({ items: this.actions(), idPrefix: 'notebook_file_swipe' })
  }

  @Builder
  badge(label: string, background: string, foreground: string = '#E8E8E8') {
    Text(label).fontSize(11).fontColor(foreground).maxLines(1)
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .backgroundColor(background).borderRadius(10)
  }

  @Builder
  summary() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Text(this.title()).fontSize(16).fontColor(UiColor.text).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1).constraintSize({ minWidth: 0 })
        Text(fileModifiedLabel(this.file.modifiedAt, true)).fontSize(12).fontColor(UiColor.secondary)
          .maxLines(1).flexShrink(0)
      }.width('100%').alignItems(VerticalAlign.Center)
    }.width('100%').constraintSize({ minHeight: 44 }).padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .backgroundColor(Color.Transparent).borderRadius(8)
      .accessibilityText(`${this.title()}，${fileModifiedLabel(this.file.modifiedAt)}`)
      .accessibilityDescription(this.isTrashEntry() ? '打开废纸篓' : this.expanded ? '收起文件详情' : '展开文件详情')
      .onClick((): void => { this.activateSummary() })
  }

  @Builder
  details() {
    Column({ space: 4 }) {
      if (this.file.project() !== null || this.usages.length > 0 || this.file.hasConflict) {
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(4), cross: LengthMetrics.vp(4) } }) {
          ForEach(this.usages, (kind: FileTargetKind) => {
            this.badge(fileTargetName(kind), this.usageColor(kind))
          }, (kind: FileTargetKind) => kind)
          if (this.file.project() !== null) this.badge('项目', '#3A536A')
          if (this.file.hasConflict) this.badge('冲突', UiColor.conflictBadge, UiColor.error)
        }.width('100%')
      }
      Row({ space: 8 }) {
        Column({ space: 4 }) {
          Text(filePathLabel(this.file.path)).fontSize(13).fontColor(UiColor.text)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          Text(`${fileTaskCount(this.file)} 个任务 · ${fileSizeLabel(this.file.byteLength)}`)
            .fontSize(12).fontColor(UiColor.secondary)
        }.layoutWeight(1).constraintSize({ minWidth: 0 }).alignItems(HorizontalAlign.Start)
        Button('打开', { type: ButtonType.Normal }).fontSize(13).fontColor(UiColor.primary)
          .height(44).padding({ left: 8, right: 0 }).flexShrink(0).backgroundColor(Color.Transparent)
          .accessibilityText(`打开${this.title()}`).onClick((): void => { this.openFile() })
      }.width('100%').alignItems(VerticalAlign.Center)
    }.width('100%').padding({ left: 8, right: 8, bottom: 6 }).alignItems(HorizontalAlign.Start)
  }

  build() {
    ListItem() {
      Column() {
        this.summary()
        if (this.expanded) this.details()
      }.width('100%')
    }.swipeAction(this.actionsEnabled ? {
      end: { builder: this.swipeMenu }, edgeEffect: SwipeEdgeEffect.None
    } : {})
  }
}
