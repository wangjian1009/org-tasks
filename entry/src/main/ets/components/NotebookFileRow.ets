import { SYSTEM_REPOSITORY_ID, TRASH_FILE } from '../models/SystemRepository'
import { PageNavigator } from '../services/PageNavigator'
import { CoreOrgFileMetadata } from '../services/NativeCoreService'
import { PageParameters } from '../services/PagePath'
import { FileTargetKind } from '../services/FileTargetService'
import { FileItem } from './FileItem'
import { TaskSwipeActions } from './TaskSwipeActions'
import { TaskActionItem } from '../ui/TaskActionPresentation'
import { UiColor } from '../ui/Theme'

// 仓库导航与文件行展示分离，历史备份直接复用 FileItem。
@Component
export struct NotebookFileRow {
  @Prop file: CoreOrgFileMetadata
  @Prop configRepoId: string = ''
  @Prop usages: FileTargetKind[] = []
  @Prop actionsEnabled: boolean = false
  closeSwipe: () => void = () => {}
  remove: () => void = () => {}

  openFile(editHeader: boolean = false) {
    try {
      if (this.configRepoId === SYSTEM_REPOSITORY_ID && this.file.path === TRASH_FILE) {
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
      { id: 'delete', title: '删除', label: '删除文件', icon: $r('app.media.ui_delete'), style: 'danger',
        action: (): void => { this.closeSwipe(); this.remove() } }
    ]
  }

  @Builder
  swipeMenu() {
    TaskSwipeActions({ items: this.actions(), idPrefix: 'notebook_file_swipe' })
  }

  build() {
    ListItem() {
      FileItem({ file: this.file, usages: this.usages, status: this.file.hasConflict ? '冲突' : '',
        statusColor: UiColor.error, statusBackgroundColor: UiColor.conflictBadge,
        open: (): void => { this.openFile() } })
    }.swipeAction(this.actionsEnabled ? {
      end: { builder: this.swipeMenu }, edgeEffect: SwipeEdgeEffect.None
    } : {})
  }
}
