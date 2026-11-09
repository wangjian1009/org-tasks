import { CoreNotificationsView } from './CoreNotificationsView'
import { EmptyState } from './Controls'

// 加载、错误与空列表也保留同一可滚动通知入口，不把通知固定在工具栏下。
@Component
export struct NotificationEmptyState {
  @Prop title: string = ''
  @Prop detail: string = ''
  @Prop actionLabel: string = ''
  @Prop busy: boolean = false
  action: () => void = () => {}
  @State viewportHeight: number = 400

  build() {
    Scroll() {
      Column() {
        CoreNotificationsView()
        EmptyState({ title: this.title, detail: this.detail, actionLabel: this.actionLabel, busy: this.busy, action: this.action })
          .height(this.viewportHeight)
      }.width('100%')
    }.width('100%').layoutWeight(1).edgeEffect(EdgeEffect.None)
      .onAreaChange((oldArea: Area, newArea: Area): void => {
        const height = parseFloat(newArea.height.toString())
        if (Number.isFinite(height) && height > 0 && height !== this.viewportHeight) this.viewportHeight = height
      })
      .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
  }
}
