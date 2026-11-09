import { CoreOrgFileMetadata } from '../services/NativeCoreService'
import { FileTargetKind } from '../services/FileTargetService'
import { FileItem } from './FileItem'
import { UiColor } from '../ui/Theme'

// 仓库导航与文件行展示分离，历史备份直接复用 FileItem。
@Component
export struct NotebookFileRow {
  @Prop file: CoreOrgFileMetadata
  @Prop usages: FileTargetKind[] = []

  build() {
    FileItem({ file: this.file, usages: this.usages, status: this.file.hasConflict ? '冲突' : '', statusColor: UiColor.error, open: (): void => {
      this.getUIContext().getRouter().pushUrl({ url: this.file.hasConflict ? 'pages/ConflictFile' : 'pages/FileDetail', params: { repoId: this.file.repoId, path: this.file.path } })
    } })
  }
}
