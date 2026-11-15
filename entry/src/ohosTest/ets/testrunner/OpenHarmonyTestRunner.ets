import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { RepositorySyncService, SyncStartPolicy } from '../../../main/ets/services/RepositorySyncService'
import { AppConfigService } from '../../../main/ets/services/AppConfigService'
import { localDate } from '../../../main/ets/ui/Theme'

interface EntryMonitor { abilityName: string }

// 只向专用模拟器安装隔离数据；界面验收由宿主工具与 APP HTTP 接口完成。
export default class OpenHarmonyTestRunner implements TestRunner {
  onPrepare(): void {}
  onRun(): void {
    this.seed().then(async (): Promise<void> => {
      await abilityDelegatorRegistry.getAbilityDelegator().finishTest('专用模拟器数据准备完成', 0)
    }).catch(async (error: Error): Promise<void> => {
      await abilityDelegatorRegistry.getAbilityDelegator().finishTest(`数据准备失败：${error.message}`, 1)
    })
  }
  private async seed(): Promise<void> {
    try {
    const delegator = abilityDelegatorRegistry.getAbilityDelegator()
    const monitor: EntryMonitor = { abilityName: 'EntryAbility' }
    await delegator.addAbilityMonitor(monitor)
    await delegator.startAbility({ bundleName: 'com.example.orgtasks', moduleName: 'entry', abilityName: 'EntryAbility' })
    const ability = await delegator.waitAbilityMonitor(monitor, 10000)
    const context = ability.context
    const notificationWebDav = abilityDelegatorRegistry.getArguments().parameters['-s notificationWebDav'] === 'true'
    const testDirectory = notificationWebDav ? `notification-data-qa-${Date.now()}` : 'today-data-qa'
    const directory = `${context.filesDir}/${testDirectory}`
    const today = localDate(new Date())
    const tomorrow = localDate(new Date(Date.now() + 86400000))
    if (!await fs.access(directory)) await fs.mkdir(directory, true)
    const source = `#+TITLE: 模拟器任务\n#+CATEGORY: 验证\n* TODO QA编辑\nSCHEDULED: <${today}>\n原备注\n* TODO QA联动\nSCHEDULED: <${today}>\n:PROPERTIES:\n:TRIGGER: next-sibling todo!(DONE)\n:END:\n* TODO QA关联\nSCHEDULED: <${today}>\n* TODO QA失败\nSCHEDULED: <${today}>\n:PROPERTIES:\n:TRIGGER: self todo!(INVALID)\n:END:\n* TODO QA随时\n原备注\n* TODO QA计划\nSCHEDULED: <${tomorrow}>\n原备注\n* TODO QA日程\nSCHEDULED: <${tomorrow} 10:00>\n原备注\n* DONE QA日志\nCLOSED: [${today} 09:00]\n:LOGBOOK:\n- State "DONE" from "TODO" [${today} 09:00]\n:END:\n`
    const file = await fs.open(`${directory}/tasks.org`, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
    try { await fs.write(file.fd, source); await fs.fsync(file.fd) } finally { await fs.close(file) }
    const project = await fs.open(`${directory}/project.org`, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
    try { await fs.write(project.fd, '#+TITLE: 项目验收\n#+FILETAGS: :project:\n#+PROJECT_NAME: 项目验收\n* TODO QA项目\n原备注\n'); await fs.fsync(project.fd) } finally { await fs.close(project) }
    const someday = await fs.open(`${directory}/someday.org`, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
    try { await fs.write(someday.fd, '#+TITLE: 某天验收\n* TODO QA某天\n原备注\n'); await fs.fsync(someday.fd) } finally { await fs.close(someday) }
    const config = await AppConfigService.load(context, false)
    config.repos = [{ id: 'today-simulator-qa', name: '模拟器验证', rootDirectory: directory, webdavEnabled: notificationWebDav,
      webdavUrl: notificationWebDav ? `http://127.0.0.1:18789/${testDirectory}/` : '',
      webdavUsername: notificationWebDav ? 'qa' : '', webdavPassword: notificationWebDav ? 'qa' : '', excludedDirectories: [] }]
    config.inboxRepoId = 'today-simulator-qa'; config.inboxFile = 'tasks.org'
    config.somedayRepoId = 'today-simulator-qa'; config.somedayFile = 'someday.org'; config.memoRepoId = ''; config.memoFile = ''
    if (notificationWebDav) config.todoDefaults = '#+TODO: TODO INPROGRESS | DONE'
    await AppConfigService.save(context, config)
    if (notificationWebDav) {
      const request = RepositorySyncService.start(context, { triggerReason: 'manual', policy: SyncStartPolicy.Wait })
      if (request.kind === 'rejected') throw new Error('数据准备同步未被接受')
      const completion = await request.handle.completion
      if (completion.status !== 'succeeded') throw new Error(completion.message || '数据准备同步失败')
    }
    } catch (error) { throw error as Error }
  }
}
