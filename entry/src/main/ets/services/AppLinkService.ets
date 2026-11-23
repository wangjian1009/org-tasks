import { bundleManager, common, Context, Want, wantConstant } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { util } from '@kit.ArkTS'
import { PreferencesStore } from './PreferencesStore'
import { AppLinkAssociation, AppLinkCatalogEntry, AppLinkLaunch } from '../models/OrgTask'

const PREFERENCES = 'org_tasks_config'
export const APP_LINK_ASSOCIATIONS_KEY = 'appLinkAssociations'
const CATALOG_FILE = 'app-links/apps.json'

interface AppLinkCatalogDocument { apps: AppLinkCatalogEntry[] }

export interface AppLinkTargetStatus {
  availability: 'installed' | 'missing' | 'disabled' | 'unknown'
  icon?: Resource
}

// 应用关联只保存链接名称和目录应用身份；密码、文件内容和 Org 语义不进入这里。
export class AppLinkManager {
  static readonly shared: AppLinkManager = new AppLinkManager()
  private context: Context | undefined = undefined
  private static catalogCache: AppLinkCatalogEntry[] | undefined = undefined
  private associations: AppLinkAssociation[] | undefined = undefined

  start(context: Context): void { this.context = context }
  invalidateAssociations(): void { this.associations = undefined }
  stop(): void {
    this.context = undefined
    this.associations = undefined
    AppLinkManager.catalogCache = undefined
  }
  private use(context?: Context): Context {
    if (context) this.context = context
    if (!this.context) throw new Error('应用关联管理器尚未启动')
    return this.context
  }

  async catalog(context?: Context): Promise<AppLinkCatalogEntry[]> {
    const current = this.use(context)
    if (AppLinkManager.catalogCache) return AppLinkManager.catalogCache.slice()
    let bytes: Uint8Array
    try { bytes = await current.resourceManager.getRawFileContent(CATALOG_FILE) }
    catch (error) { throw error as Error }
    const value = JSON.parse(util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(bytes)) as AppLinkCatalogDocument
    const apps = Array.isArray(value.apps) ? value.apps : []
    AppLinkManager.catalogCache = normalizeCatalog(apps)
    return AppLinkManager.catalogCache.slice()
  }

  async targetStatus(bundleName: string): Promise<AppLinkTargetStatus> {
    try {
      const info = await bundleManager.getBundleInfo(bundleName, bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
      return { availability: 'installed', icon: info.appInfo.iconResource }
    } catch (error) {
      const code = (error as BusinessError).code
      if (code === 17700001) return { availability: 'missing' }
      if (code === 17700026) return { availability: 'disabled' }
      return { availability: 'unknown' }
    }
  }

  async bindingCandidates(context: Context, name: string): Promise<AppLinkCatalogEntry[]> {
    const catalog = (await this.catalog(context)).filter((app: AppLinkCatalogEntry): boolean => app.launch !== undefined)
    const candidates = await Promise.all(catalog.map(async (app: AppLinkCatalogEntry): Promise<AppLinkCatalogEntry | undefined> => {
      const status = await this.targetStatus(app.id)
      if (status.availability === 'missing' || status.availability === 'disabled') return undefined
      return { id: app.id, name: app.name, aliases: app.aliases, icon: app.icon, launch: app.launch, iconResource: status.icon }
    }))
    const result = candidates.filter((app: AppLinkCatalogEntry | undefined): boolean => app !== undefined) as AppLinkCatalogEntry[]
    return result.sort((left: AppLinkCatalogEntry, right: AppLinkCatalogEntry): number =>
      Number(right.name === name || right.aliases?.includes(name) === true) -
      Number(left.name === name || left.aliases?.includes(name) === true))
  }

  async load(context?: Context, reload: boolean = false): Promise<AppLinkAssociation[]> {
    const current = this.use(context)
    if (this.associations && !reload) return this.associations.slice()
    const store = await PreferencesStore.open(current, PREFERENCES)
    const encoded = await store.get(APP_LINK_ASSOCIATIONS_KEY, '') as string
    if (!encoded) { this.associations = []; return [] }
    try {
      const values = JSON.parse(encoded) as AppLinkAssociation[]
      if (!Array.isArray(values)) return []
      this.associations = normalize(values)
    } catch (_) { this.associations = [] }
    return this.associations.slice()
  }

  async find(context: Context, name: string): Promise<AppLinkAssociation | undefined> {
    const normalized = normalizeName(name)
    if (!normalized) return undefined
    return (await this.load(context)).find((item: AppLinkAssociation): boolean => item.name === normalized)
  }

  async bind(context: Context, name: string, bundleName: string): Promise<void> {
    const value = normalizeAssociation({ name, bundleName })
    if (!value) throw new Error('应用链接关联不能为空')
    if (!(await this.catalog(context)).some((item: AppLinkCatalogEntry): boolean => item.id === value.bundleName && item.launch !== undefined)) {
      throw new Error('应用目录中没有此应用的启动配置')
    }
    const values = await this.load(context)
    const index = values.findIndex((item: AppLinkAssociation): boolean => item.name === value.name)
    if (index >= 0 && values[index].bundleName === value.bundleName) return
    if (index < 0) values.push(value); else values[index] = value
    await this.write(context, values)
    this.associations = values
  }

  async remove(context: Context, name: string): Promise<void> {
    const normalized = normalizeName(name)
    const values = (await this.load(context)).filter((item: AppLinkAssociation): boolean => item.name !== normalized)
    await this.write(context, values)
    this.associations = values
  }

  private async write(context: Context, values: AppLinkAssociation[]): Promise<void> {
    const store = await PreferencesStore.open(this.use(context), PREFERENCES)
    const previous = await store.get(APP_LINK_ASSOCIATIONS_KEY, '') as string
    try {
      await store.put(APP_LINK_ASSOCIATIONS_KEY, JSON.stringify(normalize(values)))
      await store.flush()
    } catch (error) {
      try { await store.put(APP_LINK_ASSOCIATIONS_KEY, previous); await store.flush() }
      catch (_) { console.error('恢复应用关联失败') }
      throw error as Error
    }
  }
}

export async function openAppLink(context: common.UIAbilityContext, association: AppLinkAssociation, href: string): Promise<void> {
  const catalog = await AppLinkManager.shared.catalog(context)
  const app = catalog.find((item: AppLinkCatalogEntry): boolean => item.id === association.bundleName)
  if (!app?.launch) throw new Error('应用目录中没有此应用的启动配置')
  const want: Want = { bundleName: app.id, moduleName: app.launch.moduleName, abilityName: app.launch.abilityName }
  if (app.launch.forwardLink) {
    want.uri = href
    want.action = 'ohos.want.action.viewData'
    want.flags = wantConstant.Flags.FLAG_START_WITHOUT_TIPS
  }
  try { await context.startAbility(want) }
  catch (error) { throw error as Error }
}

export function appLinkName(uri: string): string {
  const value = uri.trim()
  if (!value.toLowerCase().startsWith('app:')) return ''
  let name = value.substring(4)
  if (name.startsWith('//')) name = name.substring(2)
  try { name = decodeURIComponent(name) } catch (_) {}
  return normalizeName(name)
}

function normalizeName(value: string): string {
  return (value || '').trim()
}

function normalizeAssociation(value: AppLinkAssociation): AppLinkAssociation | undefined {
  const name = normalizeName(value.name)
  const bundleName = (value.bundleName || '').trim()
  if (!name || !bundleName) return undefined
  return { name, bundleName }
}

function normalize(values: AppLinkAssociation[]): AppLinkAssociation[] {
  const result: AppLinkAssociation[] = []
  values.forEach((value: AppLinkAssociation): void => {
    const normalized = normalizeAssociation(value)
    if (normalized && !result.some((item: AppLinkAssociation): boolean => item.name === normalized.name)) result.push(normalized)
  })
  return result
}

function normalizeCatalog(values: AppLinkCatalogEntry[]): AppLinkCatalogEntry[] {
  const result: AppLinkCatalogEntry[] = []
  values.forEach((value: AppLinkCatalogEntry): void => {
    const id = (value.id || '').trim()
    const name = (value.name || '').trim()
    if (!id || !name || result.some((item: AppLinkCatalogEntry): boolean => item.id === id)) return
    const moduleName = value.launch?.moduleName?.trim()
    const abilityName = value.launch?.abilityName?.trim()
    const launch: AppLinkLaunch | undefined = moduleName && abilityName ?
      { moduleName, abilityName, forwardLink: value.launch?.forwardLink === true } : undefined
    result.push({ id, name, aliases: value.aliases, icon: value.icon, launch })
  })
  return result
}
