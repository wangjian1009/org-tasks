import { CoreOrgFileMetadata } from '../services/NativeCoreService'
import { FileTargetKind } from '../services/FileTargetService'
import { FileItem } from './FileItem'

// 仓库导航与文件行展示分离，历史备份直接复用 FileItem。
@Component
export struct NotebookFileRow {
  @Prop file: CoreOrgFileMetadata
  @Prop usages: FileTargetKind[] = []

  build() {
    FileItem({ file: this.file, usages: this.usages, open: (): void => {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/FileDetail', params: { repoId: this.file.repoId, path: this.file.path } })
    } })
  }
}
