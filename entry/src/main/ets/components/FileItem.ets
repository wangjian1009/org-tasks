import { CoreOrgFileMetadata, CoreTitlePart } from '../services/NativeCoreService'
import { FileTargetKind, fileTargetName } from '../services/FileTargetService'
import { fileModifiedLabel, fileSizeLabel } from '../ui/NotebookPresentation'
import { UiColor } from '../ui/Theme'
import { TitleText } from './TitleText'

@Component
export struct FileItem {
  @Prop file: CoreOrgFileMetadata
  @Prop usages: FileTargetKind[] = []
  @Prop status: string = ''
  @Prop statusColor: string = UiColor.secondary
  open: () => void = () => {}

  usageColor(kind: FileTargetKind): string {
    return kind === 'inbox' ? '#355F5A' : kind === 'someday' ? '#594A73' : '#655837'
  }

  accessibilityLabel(): string {
    const title = this.file.titleParts.length > 0
      ? this.file.titleParts.map((part: CoreTitlePart): string => part.text).join('')
      : this.file.title || this.file.path
    const usages = this.usages.map((kind: FileTargetKind): string => fileTargetName(kind)).join('、')
    return `${title}${this.status ? `，${this.status}` : ''}${usages ? `，用途 ${usages}` : ''}，文件 ${this.file.path}，${this.file.taskCount} 条笔记，${fileSizeLabel(this.file.byteLength)}，${fileModifiedLabel(this.file.modifiedAt)}`
  }

  build() {
    Column({ space: 2 }) {
      Row({ space: 8 }) {
        Flex({ direction: FlexDirection.Row, wrap: FlexWrap.NoWrap, alignItems: ItemAlign.Center }) {
          TitleText({ text: (this.file.title || '').trim() || this.file.path, parts: this.file.titleParts, lineLimit: 1 })
            .flexShrink(1).constraintSize({ minWidth: 0 })
          if (this.status.length > 0) {
            Text(this.status).fontSize(11).fontColor(this.statusColor).padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor(UiColor.container).borderRadius(8).margin({ left: 6 }).flexShrink(0)
          }
          if (this.usages.length > 0) {
            Row({ space: 4 }) {
              ForEach(this.usages, (kind: FileTargetKind) => {
                Text(fileTargetName(kind)).fontSize(11).fontColor('#E8E8E8').maxLines(1)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .backgroundColor(this.usageColor(kind)).borderRadius(10).flexShrink(0)
              }, (kind: FileTargetKind) => kind)
            }.margin({ left: 6 }).flexShrink(0)
          }
        }.layoutWeight(1).constraintSize({ minWidth: 0 })
        Text(`${this.file.taskCount} 条`).fontSize(12).fontColor(UiColor.secondary).maxLines(1).flexShrink(0)
      }.width('100%').height(24).alignItems(VerticalAlign.Center)
      Row({ space: 8 }) {
        Row({ space: 4 }) {
          if ((this.file.title || '').trim().length > 0) {
            Text(this.file.path).fontSize(12).fontColor(UiColor.secondary).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1).constraintSize({ minWidth: 0 })
            Text('·').fontSize(12).fontColor(UiColor.secondary).flexShrink(0)
          }
          Text(fileSizeLabel(this.file.byteLength)).fontSize(12).fontColor(UiColor.secondary).maxLines(1).flexShrink(0)
        }.layoutWeight(1).constraintSize({ minWidth: 0 })
        Text(fileModifiedLabel(this.file.modifiedAt, true)).fontSize(11).fontColor(UiColor.secondary)
          .maxLines(1).flexShrink(0)
      }.width('100%').height(18).alignItems(VerticalAlign.Center)
    }.width('100%').height(56).padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Center)
      .accessibilityGroup(true).accessibilityText(this.accessibilityLabel())
      .onClick((): void => { this.open() })
  }
}
