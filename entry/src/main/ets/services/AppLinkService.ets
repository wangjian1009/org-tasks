import { Context } from '@kit.AbilityKit'
import { bundleManager } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { PreferencesStore } from './PreferencesStore'
import { AppLinkAssociation, AppLinkCatalogEntry } from '../models/OrgTask'

const PREFERENCES = 'org_tasks_config'
const KEY = 'appLinkAssociations'
const CATALOG_FILE = 'app-links/apps.json'

interface AppLinkCatalogDocument {
  version: number
  apps: AppLinkCatalogEntry[]
}

// 应用关联只保存链接名称和目录应用身份；密码、文件内容和 Org 语义不进入这里。
export class AppLinkManager {
  static readonly shared: AppLinkManager = new AppLinkManager()
  private context: Context | undefined = undefined
  private static catalogCache: AppLinkCatalogEntry[] | undefined = undefined
  private associations: AppLinkAssociation[] | undefined = undefined

  start(context: Context): void { this.context = context }
  stop(): void { this.context = undefined; this.associations = undefined; AppLinkManager.catalogCache = undefined }
  private use(context?: Context): Context {
    if (context) this.context = context
    if (!this.context) throw new Error('应用关联管理器尚未启动')
    return this.context
  }

  async catalog(context?: Context): Promise<AppLinkCatalogEntry[]> {
    const current = this.use(context)
    if (AppLinkManager.catalogCache) return AppLinkManager.catalogCache.slice()
    try {
      const bytes = await current.resourceManager.getRawFileContent(CATALOG_FILE)
      const value = JSON.parse(util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(bytes)) as AppLinkCatalogDocument
      const apps = Array.isArray(value.apps) ? value.apps : []
      const catalog = normalizeCatalog(apps)
      const installed: AppLinkCatalogEntry[] = []
      for (const app of catalog) {
        try {
          const info = await bundleManager.getBundleInfo(app.id, bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
          app.iconResource = info.appInfo.iconResource
          if (app.iconResource) installed.push(app)
        } catch (_) { /* 未安装、权限不足或资源缺失的目录项不显示。 */ }
      }
      AppLinkManager.catalogCache = installed
    } catch (_) { AppLinkManager.catalogCache = [] }
    return AppLinkManager.catalogCache.slice()
  }

  async load(context?: Context, reload: boolean = false): Promise<AppLinkAssociation[]> {
    const current = this.use(context)
    if (this.associations && !reload) return this.associations.slice()
    const store = await PreferencesStore.open(current, PREFERENCES)
    const encoded = await store.get(KEY, '') as string
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

  async upsert(context: Context, association: AppLinkAssociation): Promise<void> {
    const value = normalizeAssociation(association)
    if (!value) throw new Error('应用链接关联不能为空')
    const values = await this.load(context)
    const index = values.findIndex((item: AppLinkAssociation): boolean => item.name === value.name)
    if (index < 0) values.push(value); else values[index] = value
    await this.write(context, values)
    this.associations = values
  }

  async update(context: Context, oldName: string, association: AppLinkAssociation): Promise<void> {
    const value = normalizeAssociation(association)
    if (!value) throw new Error('应用链接关联不能为空')
    const values = await this.load(context)
    const old = normalizeName(oldName)
    const index = values.findIndex((item: AppLinkAssociation): boolean => item.name === old)
    if (index < 0) throw new Error('应用链接关联已不存在')
    const duplicate = values.some((item: AppLinkAssociation, itemIndex: number): boolean => itemIndex !== index && item.name === value.name)
    if (duplicate) throw new Error('该应用链接名称已经存在')
    values[index] = value
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
    await store.put(KEY, JSON.stringify(normalize(values)))
    await store.flush()
  }
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
  const moduleName = (value.moduleName || '').trim()
  const abilityName = (value.abilityName || '').trim()
  if (!name || !bundleName) return undefined
  return { name, bundleName, moduleName, abilityName }
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
    if (id && name && !result.some((item: AppLinkCatalogEntry): boolean => item.id === id)) result.push({ id, name })
  })
  return result
}
