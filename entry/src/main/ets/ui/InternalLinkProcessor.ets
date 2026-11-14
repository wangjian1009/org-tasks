import { webview } from '@kit.ArkWeb'

export interface InternalLinkProcessor {
  isValid(target: string): Promise<boolean>
  process(target: string): Promise<void>
}

// 只读取 Core 投影的目的地键与优先级，不解析 Org 或从显示文字猜测目标。
export function documentInternalLinkScript(target: string, execute: boolean): string {
  return `(() => {
    const target = ${JSON.stringify(target)};
    const nodes = [...document.querySelectorAll('[data-org-link-targets]')].filter(node => {
      try { return JSON.parse(node.getAttribute('data-org-link-targets')).includes(target); } catch (_) { return false; }
    }).sort((a, b) => Number(a.getAttribute('data-org-link-priority')) - Number(b.getAttribute('data-org-link-priority')));
    const node = nodes[0];
    if (!node) return false;
    if (${execute}) {
      for (let parent = node; parent; parent = parent.parentElement) if (parent.matches('details')) parent.open = true;
      node.scrollIntoView({ block: 'start', behavior: 'auto' });
    }
    return true;
  })()`
}

export class DocumentInternalLinkProcessor implements InternalLinkProcessor {
  private controller: webview.WebviewController
  constructor(controller: webview.WebviewController) { this.controller = controller }
  async isValid(target: string): Promise<boolean> {
    try { return await this.controller.runJavaScript(documentInternalLinkScript(target, false)) === 'true' }
    catch (_) { return false }
  }
  async process(target: string): Promise<void> {
    try {
      if (await this.controller.runJavaScript(documentInternalLinkScript(target, true)) !== 'true') throw new Error('内部链接目标不存在')
    } catch (_) { throw new Error('内部链接目标不存在或文档尚未载入') }
  }
}

// 提供具名对象实现，方便原生文档把目的地映射到自己的滚动容器。
export class CallbackInternalLinkProcessor implements InternalLinkProcessor {
  private valid: (target: string) => Promise<boolean>
  private follow: (target: string) => Promise<void>
  constructor(valid: (target: string) => Promise<boolean>, follow: (target: string) => Promise<void>) {
    this.valid = valid; this.follow = follow
  }
  async isValid(target: string): Promise<boolean> { return this.valid(target) }
  async process(target: string): Promise<void> { await this.follow(target) }
}
