import { InternalLinkProcessor } from '../../ui/InternalLinkProcessor'
import { CoreContentBlock, CoreTextLink, CoreLinkValue } from '../../services/NativeCoreService'
import { TaskTextBlock } from './TaskTextBlock'
import { TaskListBlock } from './TaskListBlock'
import { TaskTableBlock } from './TaskTableBlock'
import { TaskChecklistBlock } from './TaskChecklistBlock'
import { TaskBlockController } from '../../ui/TaskBlockController'
import { LinkEditController } from '../LinkView'
import { UiColor } from '../../ui/Theme'
import { projectContentGap } from '../../ui/ProjectReadingPresentation'

@Component
export struct TaskContentBlocks {
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop blocks: CoreContentBlock[] = []
  @Prop readonly: boolean = false
  @Prop projectReading: boolean = false
  @Prop disabled: boolean = false
  @Prop revision: string = ''
  @Prop contentBackground: string = UiColor.taskCard
  @Prop ownerKey: string = ''
  editor: TaskBlockController = new TaskBlockController()
  linkEditor: LinkEditController = new LinkEditController()
  begin: (block: CoreContentBlock) => Promise<boolean> = async () => true
  save: (block: CoreContentBlock, source: string) => Promise<boolean> = async () => false
  changeLink: ((block: CoreContentBlock, link: CoreTextLink, value: CoreLinkValue | null) => Promise<void>) | undefined = undefined
  editingChanged: (editing: boolean) => void = () => {}
  linkEditingChanged: (editing: boolean) => void = () => {}
  @BuilderParam checklist: (block: CoreContentBlock) => void = this.readChecklist

  @Builder
  readChecklist(block: CoreContentBlock) {
    TaskChecklistBlock({ items: block.items, readonly: this.readonly, ownerKey: this.ownerKey, blockId: block.id }).width('100%')
  }

  build() {
    Column({ space: this.projectReading ? 0 : 12 }) {
      ForEach(this.blocks, (block: CoreContentBlock, index: number) => {
        Column() {
          if (block.kind === 'checklist') {
            this.checklist(block)
          } else if (block.kind === 'list') {
            TaskListBlock({ internalLinkProcessor: this.internalLinkProcessor, block, readonly: this.readonly, disabled: this.disabled, revision: this.revision, projectReading: this.projectReading,
              contentBackground: this.contentBackground, ownerKey: this.ownerKey, editor: this.editor, linkEditor: this.linkEditor,
              begin: this.begin, save: this.save, changeLink: this.changeLink, editingChanged: this.editingChanged,
              linkEditingChanged: this.linkEditingChanged }).width('100%')
          } else if (block.kind === 'table') {
            TaskTableBlock({ internalLinkProcessor: this.internalLinkProcessor, block, readonly: this.readonly, disabled: this.disabled, revision: this.revision, projectReading: this.projectReading,
              contentBackground: this.contentBackground, ownerKey: this.ownerKey, editor: this.editor, linkEditor: this.linkEditor,
              begin: this.begin, save: this.save, changeLink: this.changeLink, editingChanged: this.editingChanged,
              linkEditingChanged: this.linkEditingChanged }).width('100%')
          } else {
            TaskTextBlock({ internalLinkProcessor: this.internalLinkProcessor, block, readonly: this.readonly, disabled: this.disabled, revision: this.revision, projectReading: this.projectReading,
              contentBackground: this.contentBackground, ownerKey: this.ownerKey, editor: this.editor, linkEditor: this.linkEditor,
              begin: this.begin, save: this.save, changeLink: this.changeLink, editingChanged: this.editingChanged,
              linkEditingChanged: this.linkEditingChanged }).width('100%')
          }
        }.width('100%').margin({ top: this.projectReading ? projectContentGap(this.blocks, index) : 0 })
      }, (_block: CoreContentBlock, index: number): string => `${this.ownerKey}:${index}`)
    }.width('100%')
  }
}
