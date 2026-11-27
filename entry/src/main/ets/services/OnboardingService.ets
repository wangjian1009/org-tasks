import { Context } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { fileIo } from '@kit.CoreFileKit'
import { AppConfig } from '../models/OrgTask'
import { isSystemRepository, ONBOARDING_FILE } from '../models/SystemRepository'
import { displayLocale } from '../ui/LocalizedText'
import { AppConfigService } from './AppConfigService'
import { NativeCoreService } from './NativeCoreService'
import { PageRoute } from './PagePath'
import { PreferencesStore } from './PreferencesStore'

const STORE = 'org_tasks_onboarding'
const CREATED = 'projectCreated'

// 安装级标记在设置重置和项目删除后保留。
export async function prepareOnboarding(context: Context): Promise<PageRoute | undefined> {
  const store = await PreferencesStore.open(context, STORE)
  if (await store.get(CREATED, false)) return undefined
  const config = await AppConfigService.load(context, false)
  const repository = config.repos.find(isSystemRepository)!
  let exists: boolean
  try { exists = await fileIo.access(`${repository.rootDirectory}/${ONBOARDING_FILE}`) }
  catch (_) { throw new Error('检查新手引导文件失败') }
  const page = exists ? undefined : await createOnboarding(context, config, repository.rootDirectory)
  await store.put(CREATED, true)
  await store.flush()
  return page
}

async function createOnboarding(context: Context, config: AppConfig, rootDirectory: string): Promise<PageRoute | undefined> {
  const language = displayLocale().startsWith('en') ? 'en' : 'zh'
  let template: Uint8Array
  try { template = await context.resourceManager.getRawFileContent(`templates/onboarding-${language}.org`) }
  catch (_) { throw new Error('读取新手引导模板失败') }
  const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
  const repo = (await workspace.repos()).find(item => item.rootDirectory === rootDirectory)
  if (!repo) throw new Error('系统仓库不可用')
  await workspace.executeTaskOperations({ operations: [{ type: 'FileNew', data: {
    path: { repoId: repo.id, file: ONBOARDING_FILE, titles: [] },
    templatePath: '',
    templateContent: util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(template),
    arguments: { 'plan': util.generateRandomUUID(), 'review': util.generateRandomUUID(), 'finish': util.generateRandomUUID() },
    initTasks: []
  } }] })
  if (config.repos.length > 1) return undefined
  return { url: 'pages/OrgFileDetail', params: { repoId: repo.id, path: ONBOARDING_FILE } }
}
