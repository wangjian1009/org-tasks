import { application } from '@kit.AbilityKit'
import { i18n, resourceManager } from '@kit.LocalizationKit'

const moduleResources = new Map<string, resourceManager.ResourceManager>()

export function registerLocalizedResources(moduleName: string, resources: resourceManager.ResourceManager): void {
  moduleResources.set(moduleName, resources)
}

export function localizedText(resource: Resource, ...args: string[]): string {
  try {
    const resources = moduleResources.get(resource.moduleName) ?? application.getApplicationContext().resourceManager
    return args.length === 0 ? resources.getStringSync(resource.id) : resources.getStringSync(resource.id, ...args)
  } catch (error) {
    console.error(`读取界面字符串失败，模块：${resource.moduleName}，资源 ID：${resource.id}`)
    throw error as Error
  }
}

export function displayLocale(): string {
  const language = i18n.System.getAppPreferredLanguage()
  return language === 'en' || language.startsWith('en-') ? language : 'zh-CN'
}

export function localizedDate(date: Date, options: Intl.DateTimeFormatOptions): string {
  if (!Number.isFinite(date.getTime())) return ''
  return new Intl.DateTimeFormat(displayLocale(), options).format(date)
}
