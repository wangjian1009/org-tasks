export interface PageListOffset { index: number; offset: number; anchor?: number; key?: string }

// 页面替换路由后复用会话内阅读位置，不与任务确认版本或磁盘数据缓存绑定。
export class PageListPosition {
  private static values: Map<string, PageListOffset> = new Map()
  static read(key: string): PageListOffset { return PageListPosition.values.get(key) ?? { index: 0, offset: 0 } }
  static save(key: string, index: number, offset: number, anchor?: number, itemKey?: string): void {
    if (key) PageListPosition.values.set(key, { index: Math.max(0, index), offset: Math.max(0, offset), anchor, key: itemKey })
  }
}
