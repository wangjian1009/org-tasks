import { SYSTEM_REPOSITORY_ID, TRASH_FILE } from '../models/SystemRepository'
import { PageNavigator } from '../services/PageNavigator'
import { CoreOrgFileMetadata } from '../services/NativeCoreService'
import { FileTargetKind } from '../services/FileTargetService'
import { FileItem } from './FileItem'
import { UiColor } from '../ui/Theme'

// 仓库导航与文件行展示分离，历史备份直接复用 FileItem。
@Component
export struct NotebookFileRow {
  @Prop file: CoreOrgFileMetadata
  @Prop configRepoId: string = ''
  @Prop usages: FileTargetKind[] = []

  openFile() {
    try {
      if (this.configRepoId === SYSTEM_REPOSITORY_ID && this.file.path === TRASH_FILE) {
        PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/Trash' }); return
      }
      const resolveConflict = this.file.project() === null && this.file.hasConflict
      PageNavigator.shared.pushPage(this.getUIContext(), {
        url: resolveConflict ? 'pages/ConflictFile' : 'pages/OrgFileDetail',
        params: { repoId: resolveConflict ? this.configRepoId : this.file.repoId, path: this.file.path }
      })
    } catch (_) {
      // 页面退出或路由失效时忽略此次导航。
    }
  }

  build() {
    FileItem({ file: this.file, usages: this.usages, status: this.file.hasConflict ? '冲突' : '',
      statusColor: UiColor.error, statusBackgroundColor: UiColor.conflictBadge,
      open: (): void => { this.openFile() } })
  }
}
