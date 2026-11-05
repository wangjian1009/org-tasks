import { common } from '@kit.AbilityKit'

// 链接解析由 Core 完成；宿主只调用系统能力打开支持的外部地址。
export class ExternalLinkService {
  static async open(context: common.UIAbilityContext, href: string): Promise<void> {
    const scheme = href.substring(0, href.indexOf(':')).toLowerCase()
    if (scheme === 'http' || scheme === 'https') {
      await context.openLink(href, { appLinkingOnly: false })
    } else if (scheme === 'mailto' || scheme === 'tel') {
      await context.startAbility({ action: 'ohos.want.action.viewData', uri: href })
    } else {
      throw new Error('此链接暂不支持打开')
    }
  }
}
