import { TaskContentSlot, reconcileTaskContent } from '../../ui/TaskContentPresentation'
import { InternalLinkProcessor } from '../../ui/InternalLinkProcessor'
import { CoreContentBlock, CoreTextLink, CoreLinkValue, CoreContentNode, CoreContentBlockChange, CoreTaskChecklistChange } from '../../services/NativeCoreService'
import { TaskTextBlock } from './TaskTextBlock'
import { TaskListBlock } from './TaskListBlock'
import { TaskTableBlock } from './TaskTableBlock'
import { TaskChecklistBlock } from './TaskChecklistBlock'
import { TaskNativeContent } from './TaskNativeContent'
import { TaskBlockView } from './TaskBlockView'
import { TaskBlockController } from '../../ui/TaskBlockController'
import { LinkEditController } from '../LinkView'
import { UiColor } from '../../ui/Theme'
import { projectContentGap } from '../../ui/OrgFileReadingPresentation'

@Component
export struct TaskContentEditor {
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop @Watch('contentChanged') blocks: CoreContentBlock[] = []
  @State private slots: TaskContentSlot[] = []
  @Prop contentTree: CoreContentNode[] | undefined = undefined
  beginEmpty: () => Promise<boolean> = async () => false
  writeNode: (change: CoreContentBlockChange) => Promise<void> = async () => {}
  toggle: (change: CoreTaskChecklistChange) => void = () => {}
  @Prop readonly: boolean = false
  @Prop projectReading: boolean = false
  @Prop checklistEditing: boolean = false
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
  @BuilderParam checklist: (index: number) => void = this.readChecklist

  aboutToAppear(): void { this.contentChanged() }

  contentChanged(): void {
    const next = reconcileTaskContent(this.slots, this.blocks)
    if (next !== this.slots) this.slots = next
  }

  blockFor(key: string): CoreContentBlock { return this.slots.find(slot => slot.key === key)!.block }
  indexFor(key: string): number { return this.slots.findIndex(slot => slot.key === key) }

  @Builder
  readChecklist(index: number) {
    TaskChecklistBlock({ items: this.blocks[index].items, readonly: this.readonly, ownerKey: this.ownerKey, blockId: this.blocks[index].id,
      tree: this.treeFor(this.blocks[index].id), processor: this.internalLinkProcessor, revision: this.revision }).width('100%')
  }

  treeFor(id: string): CoreContentNode | undefined { return this.contentTree?.find(node => node.id === id) }

  @Builder
  nativeBlock(block: CoreContentBlock) {
    TaskNativeContent({ nodes: [this.treeFor(block.id)!], readonly: this.readonly, disabled: this.disabled,
      revision: this.revision, processor: this.internalLinkProcessor, editor: this.editor, linkEditor: this.linkEditor,
      begin: (): Promise<boolean> => this.begin(block), write: this.writeNode, toggle: this.toggle,
      editingChanged: this.editingChanged, linkEditingChanged: this.linkEditingChanged })
  }

  build() {
    Column({ space: this.projectReading ? 0 : 12 }) {
      if (!this.readonly && this.contentTree?.length === 0) {
        TaskNativeContent({ emptyBody: true, disabled: this.disabled, revision: this.revision,
          processor: this.internalLinkProcessor, editor: this.editor, linkEditor: this.linkEditor,
          begin: this.beginEmpty, write: this.writeNode, editingChanged: this.editingChanged,
          linkEditingChanged: this.linkEditingChanged })
      }
      ForEach(this.slots, (slot: TaskContentSlot) => {
        Column() {
          if (this.blockFor(slot.key).kind === 'checklist') {
            TaskBlockView({ internalLinkProcessor: this.internalLinkProcessor, block: this.blockFor(slot.key), readonly: this.readonly, disabled: this.disabled,
              revision: this.revision, projectReading: this.projectReading, nativeChecklist: true, checklistEditing: this.checklistEditing,
              contentBackground: this.contentBackground, ownerKey: this.ownerKey, editor: this.editor, linkEditor: this.linkEditor,
              placeholder: '清单（Org 原文）', readContent: (): void => { this.checklist(this.indexFor(slot.key)) }, begin: this.begin, save: this.save,
              editingChanged: this.editingChanged }).width('100%')
          } else if (this.treeFor(this.blockFor(slot.key).id)) {
            TaskBlockView({ block: this.blockFor(slot.key), readonly: this.readonly, disabled: this.disabled,
              revision: this.revision, nativeChecklist: true, contentBackground: this.contentBackground, ownerKey: this.ownerKey,
              editor: this.editor, linkEditor: this.linkEditor, readContent: (): void => { this.nativeBlock(this.blockFor(slot.key)) },
              begin: this.begin, save: this.save, editingChanged: this.editingChanged }).width('100%')
          } else if (this.blockFor(slot.key).kind === 'list') {
            TaskListBlock({ internalLinkProcessor: this.internalLinkProcessor, block: this.blockFor(slot.key), readonly: this.readonly, disabled: this.disabled, revision: this.revision, projectReading: this.projectReading,
              contentBackground: this.contentBackground, ownerKey: this.ownerKey, editor: this.editor, linkEditor: this.linkEditor,
              begin: this.begin, save: this.save, changeLink: this.changeLink, editingChanged: this.editingChanged,
              linkEditingChanged: this.linkEditingChanged }).width('100%')
          } else if (this.blockFor(slot.key).kind === 'table') {
            TaskTableBlock({ internalLinkProcessor: this.internalLinkProcessor, block: this.blockFor(slot.key), readonly: this.readonly, disabled: this.disabled, revision: this.revision, projectReading: this.projectReading,
              contentBackground: this.contentBackground, ownerKey: this.ownerKey, editor: this.editor, linkEditor: this.linkEditor,
              begin: this.begin, save: this.save, changeLink: this.changeLink, editingChanged: this.editingChanged,
              linkEditingChanged: this.linkEditingChanged }).width('100%')
          } else {
            TaskTextBlock({ internalLinkProcessor: this.internalLinkProcessor, block: this.blockFor(slot.key), readonly: this.readonly, disabled: this.disabled, revision: this.revision, projectReading: this.projectReading,
              contentBackground: this.contentBackground, ownerKey: this.ownerKey, editor: this.editor, linkEditor: this.linkEditor,
              begin: this.begin, save: this.save, changeLink: this.changeLink, editingChanged: this.editingChanged,
              linkEditingChanged: this.linkEditingChanged }).width('100%')
          }
        }.width('100%').margin({ top: this.projectReading ? projectContentGap(this.blocks, this.indexFor(slot.key)) : 0 })
      }, (slot: TaskContentSlot): string => slot.key)
    }.width('100%')
  }
}
