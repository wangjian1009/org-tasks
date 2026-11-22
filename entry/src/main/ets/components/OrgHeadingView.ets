import { InternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { CoreTask, CoreTaskModification } from '../services/NativeCoreService'
import { TitleText } from './TitleText'
import { UiColor } from '../ui/Theme'
import { taskTagColor } from '../ui/TaskListPresentation'
import { visibleProjectTags } from '../ui/ProjectReadingPresentation'
import { PopupMenu, PopupMenuItem } from './controls/PopupMenu'
import { TaskInlineSession } from '../services/TaskInlineService'
import { RightSwipe, SwipeMenuCoordinator } from './controls/RightSwipe'
import { TaskSwipeActions } from './TaskSwipeActions'
import { TaskActionItem, taskSwipeMenuWidth } from '../ui/TaskActionPresentation'

// 普通章节保留独立标题与子树操作入口。
@Component
export struct OrgHeadingView {
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop node: CoreTask
  @Prop specialTags: string[] = []

  modify: (changes: CoreTaskModification[]) => Promise<void> = async (): Promise<void> => {}
  @Prop canOrderChildren: boolean = false
  structureActions: (canOrder: boolean) => PopupMenuItem[] = () => []
  @Prop swipeEnabled: boolean = true
  swipeActions: (close: () => void) => TaskActionItem[] = () => []
  menuCoordinator: SwipeMenuCoordinator | undefined = undefined
  @State menuOpen: boolean = false
  @State working: boolean = false
  @State message: string = ''

  archived(): boolean { return this.node.editContent.ownTags.includes('ARCHIVE') }

  async archive(): Promise<void> {
    if (this.working || !await TaskInlineSession.end(true)) return
    this.working = true; this.message = ''; this.menuOpen = false
    try {
      const tags = this.node.editContent.ownTags.filter((tag: string) => tag !== 'ARCHIVE')
      await this.modify([{ field: 'TAGS', value: this.archived() ? tags : tags.concat('ARCHIVE') }])
    } catch (error) { this.message = `归档操作失败：${(error as Error).message}` }
    finally { this.working = false }
  }

  async toggleSubtree(): Promise<void> {
    if (this.working || this.archived() || !await TaskInlineSession.end(true)) return
    this.working = true; this.message = ''; this.menuOpen = false
    try {
      await this.modify([{ field: 'PROPERTY', value: {
        name: 'VISIBILITY', value: this.node.property('VISIBILITY') === 'folded' ? null : 'folded'
      } }])
    } catch (error) { this.message = `折叠操作失败：${(error as Error).message}` }
    finally { this.working = false }
  }

  menuItems(): PopupMenuItem[] {
    const folded = this.node.property('VISIBILITY') === 'folded'
    const archived = this.archived()
    return this.structureActions(this.canOrderChildren).concat([
      { title: folded ? '展开' : '收起', icon: folded ? $r('app.media.ui_visibility') : $r('app.media.ui_visibility_off'),
        disabled: archived, action: (): void => { this.toggleSubtree() } },
      { title: archived ? '恢复' : '归档', icon: archived ? $r('app.media.ui_restore') : $r('app.media.ui_folder'),
        action: (): void => { this.archive() } }
    ])
  }

  @Builder
  headingMenu() {
    PopupMenu({ items: this.menuItems(), maximumWidth: 240, disabled: this.working,
      activate: (item: PopupMenuItem): void => { this.menuOpen = false; item.action() } })
  }

  @Builder
  headingRow() {
      Row({ space: 8 }) {
        if (this.node.level === 1) {
          Image($r('app.media.ui_document_outline')).width(20).height(20).fillColor(UiColor.secondary).accessibilityLevel('no')
        }
        if (this.archived()) {
          Text(this.node.heading).fontSize(this.node.level === 1 ? 22 : this.node.level === 2 ? 20 : 18).fontWeight(FontWeight.Medium)
            .fontColor(UiColor.secondary).layoutWeight(1).copyOption(CopyOptions.LocalDevice)
        } else {
          TitleText({ internalLinkProcessor: this.internalLinkProcessor, text: this.node.heading, parts: this.node.headingParts,
            textSize: this.node.level === 1 ? 22 : this.node.level === 2 ? 20 : 18,
            weight: FontWeight.Medium, copyable: true }).layoutWeight(1)
        }
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ui_more')).width(18).height(18).fillColor(UiColor.secondary)
        }.width(44).height(44).padding(0).backgroundColor(Color.Transparent).enabled(!this.working)
          .accessibilityText(`章节操作：${this.node.heading}`).onClick((): void => { this.menuOpen = !this.menuOpen })
          .bindPopup(this.menuOpen, { builder: this.headingMenu, placement: Placement.BottomRight,
            popupColor: UiColor.menu, backgroundBlurStyle: BlurStyle.NONE, enableArrow: false,
            onStateChange: (event): void => { this.menuOpen = event.isVisible } })
      }.width('100%').alignItems(VerticalAlign.Center)
  }

  @Builder
  headingSwipeMenu(close: () => void) {
    TaskSwipeActions({ items: this.swipeActions(close), idPrefix: 'project_heading_swipe' })
  }

  build() {
    Column({ space: 8 }) {
      RightSwipe({ disabled: true, menuCoordinator: this.menuCoordinator, content: (): void => { this.headingRow() },
        endMenu: (close: () => void): void => { this.headingSwipeMenu(close) },
        menuWidth: this.swipeEnabled && !this.working ? taskSwipeMenuWidth(this.swipeActions(() => {})) : 0,
        canOpenMenu: (): boolean => this.swipeEnabled && !this.working && !this.menuOpen && !TaskInlineSession.active() })
      if (this.node.level === 1) { Divider().color(UiColor.divider).strokeWidth(1) }
      if (this.archived()) { Text('已归档').fontSize(13).fontColor(UiColor.secondary).padding({ top: 4, bottom: 12 }) }
      if (!this.archived() && (this.node.property('VISIBILITY') === 'folded')) {
        Text('已收起').fontSize(12).fontColor(UiColor.secondary).onClick((): void => { this.toggleSubtree() })
      }
      if (this.message) { Text(this.message).fontSize(12).fontColor(UiColor.error) }
      if (!this.archived() && visibleProjectTags(this.node.ownTags, this.specialTags).length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(visibleProjectTags(this.node.ownTags, this.specialTags), (tag: string) => {
            Text(tag).fontSize(12).fontColor(UiColor.text).wordBreak(WordBreak.BREAK_ALL)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(10)
              .backgroundColor(taskTagColor(tag)).margin({ right: 6, bottom: 6 })
          }, (tag: string) => tag)
        }.width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
      .padding({ top: this.node.level === 1 ? 20 : 16, bottom: 8 })
      .accessibilityGroup(true).accessibilityText(`${this.node.level} 级标题，${this.node.heading}`)
  }
}
