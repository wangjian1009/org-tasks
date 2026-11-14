import { InternalLinkProcessor } from '../../ui/InternalLinkProcessor'
import { CoreContentBlock, CoreTextLink, CoreLinkValue } from '../../services/NativeCoreService'
import { TaskBlockView } from './TaskBlockView'
import { LinkEditController } from '../LinkView'
import { TaskBlockController } from '../../ui/TaskBlockController'
import { UiColor } from '../../ui/Theme'

@Component
export struct TaskListBlock {
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop block: CoreContentBlock
  @Prop readonly: boolean = false
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

  build() {
    TaskBlockView({ internalLinkProcessor: this.internalLinkProcessor, block: this.block, readonly: this.readonly, disabled: this.disabled, revision: this.revision,
      contentBackground: this.contentBackground, ownerKey: this.ownerKey, placeholder: '列表（Org 原文）', editor: this.editor,
      linkEditor: this.linkEditor, begin: this.begin, save: this.save, changeLink: this.changeLink,
      editingChanged: this.editingChanged, linkEditingChanged: this.linkEditingChanged }).width('100%')
  }
}
