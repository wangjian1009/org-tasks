import { UiColor, UiSize } from '../ui/Theme'

export interface PopupMenuItem {
  title: string
  icon?: Resource
  checked?: boolean
  dangerous?: boolean
  action: () => void
}

// 直接测量实际菜单行，让系统字体、字号缩放和图标占位参与同一次布局。
@Component
export struct PopupMenu {
  @Prop items: PopupMenuItem[] = []
  @Prop maximumWidth: number = 0
  @Prop disabled: boolean = false
  activate: (item: PopupMenuItem) => void = () => {}

  hasIcons(): boolean { return this.items.some(item => item.icon !== undefined) }
  // 仅为可见勾选保留一列，未选中的短菜单不产生空白尾列。
  hasSelection(): boolean { return this.items.some(item => item.checked === true) }

  onMeasureSize(self: GeometryInfo, children: Measurable[], constraint: ConstraintSizeOptions): SizeResult {
    const maximumWidth = Math.max(0, Math.min(this.maximumWidth, Number(constraint.maxWidth)))
    let width = 0
    for (const child of children) {
      const size = child.measure({ minWidth: 0, maxWidth: maximumWidth, minHeight: 0, maxHeight: Infinity })
      width = Math.max(width, size.width)
    }
    width = Math.min(maximumWidth, Math.ceil(width))
    let height = 0
    for (const child of children) {
      height += child.measure({ minWidth: width, maxWidth: width, minHeight: 0, maxHeight: Infinity }).height
    }
    return { width, height }
  }

  onPlaceChildren(self: GeometryInfo, children: Layoutable[], constraint: ConstraintSizeOptions) {
    let y = 0
    for (const child of children) {
      child.layout({ x: 0, y })
      y += child.measureResult.height
    }
  }

  build() {
    ForEach(this.items, (item: PopupMenuItem, index: number) => {
      PopupMenuRow({ item, iconColumn: this.hasIcons(), selectionColumn: this.hasSelection(),
        disabled: this.disabled, first: index === 0, activate: this.activate })
    }, (item: PopupMenuItem) => item.title)
  }
}

@Component
struct PopupMenuRow {
  @Prop item: PopupMenuItem = { title: '', action: () => {} }
  @Prop iconColumn: boolean = false
  @Prop selectionColumn: boolean = false
  @Prop disabled: boolean = false
  @Prop first: boolean = false
  activate: (item: PopupMenuItem) => void = () => {}

  onMeasureSize(self: GeometryInfo, children: Measurable[], constraint: ConstraintSizeOptions): SizeResult {
    const textIndex = this.iconColumn ? 1 : 0
    const columnsWidth = (this.iconColumn ? UiSize.menuIcon + UiSize.menuGap : 0) +
      (this.selectionColumn ? UiSize.menuIcon + UiSize.menuGap : 0)
    const maximumWidth = Number(constraint.maxWidth)
    const text = children[textIndex].measure({ minWidth: 0,
      maxWidth: Math.max(0, maximumWidth - UiSize.menuPadding * 2 - columnsWidth), minHeight: 0, maxHeight: Infinity })
    const width = Math.min(maximumWidth,
      Math.max(Number(constraint.minWidth), Math.ceil(text.width + UiSize.menuPadding * 2 + columnsWidth)))
    const height = Math.max(UiSize.menuRow, text.height + 20)
    for (let index = 0; index < children.length; index++) {
      if (index === textIndex) continue
      const button = index === children.length - 1
      children[index].measure({ minWidth: button ? width : UiSize.menuIcon, maxWidth: button ? width : UiSize.menuIcon,
        minHeight: button ? height : UiSize.menuIcon, maxHeight: button ? height : UiSize.menuIcon })
    }
    return { width, height }
  }

  onPlaceChildren(self: GeometryInfo, children: Layoutable[], constraint: ConstraintSizeOptions) {
    const textIndex = this.iconColumn ? 1 : 0
    for (let index = 0; index < children.length; index++) {
      const child = children[index]
      if (index === children.length - 1) {
        child.layout({ x: 0, y: 0 })
      } else {
        const x = index === textIndex ? UiSize.menuPadding + (this.iconColumn ? UiSize.menuIcon + UiSize.menuGap : 0) :
          index < textIndex ? UiSize.menuPadding : self.width - UiSize.menuPadding - UiSize.menuIcon
        child.layout({ x, y: (self.height - child.measureResult.height) / 2 })
      }
    }
  }

  build() {
    ForEach([this.item], (item: PopupMenuItem) => {
      if (this.iconColumn) {
        if (this.item.icon) {
          Image(this.item.icon).width(UiSize.menuIcon).height(UiSize.menuIcon).accessibilityLevel('no')
        } else {
          Row().width(UiSize.menuIcon).height(UiSize.menuIcon).accessibilityLevel('no')
        }
      }
      Text(this.item.title).fontSize(UiSize.menuFont).fontWeight(FontWeight.Normal)
        .fontColor(this.item.dangerous ? UiColor.error : UiColor.text).wordBreak(WordBreak.BREAK_WORD)
        .accessibilityLevel('no')
      if (this.selectionColumn) {
        if (this.item.checked) {
          Image($r('app.media.ui_done')).width(UiSize.menuIcon).height(UiSize.menuIcon).accessibilityLevel('no')
        } else {
          Row().width(UiSize.menuIcon).height(UiSize.menuIcon).accessibilityLevel('no')
        }
      }
      // 透明原生按钮覆盖整行，统一触摸、键盘焦点、按压反馈与无障碍名称。
      Button({ type: ButtonType.Normal }) {}.padding(0).backgroundColor(Color.Transparent).borderRadius(UiSize.menuRadius)
          .enabled(!this.disabled).defaultFocus(this.first)
          .accessibilityText(`${this.item.title}${this.item.checked === undefined ? '' : this.item.checked ? '，已选中' : '，未选中'}`)
          .onClick((): void => { if (!this.disabled) this.activate(this.item) })
    }, (item: PopupMenuItem) => item.title)
  }
}
