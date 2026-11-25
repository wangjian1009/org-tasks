import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit'
import { application } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { RepositorySyncService, SyncStartPolicy } from '../../../main/ets/services/RepositorySyncService'
import { AppConfigService } from '../../../main/ets/services/AppConfigService'
import { localDate } from '../../../main/ets/ui/Theme'
import { registerLocalizedResources } from '../../../main/ets/ui/LocalizedText'
import { probeCalendarReminders } from './CalendarReminderProbe'

interface EntryMonitor { abilityName: string }

// 隔离数据只用于专用模拟器；显式 calendarProbe 使用独立日历，支持已授权真机诊断。
export default class OpenHarmonyTestRunner implements TestRunner {
  onPrepare(): void {}
  onRun(): void {
    this.run().then(async (): Promise<void> => {
      await abilityDelegatorRegistry.getAbilityDelegator().finishTest('专用模拟器数据准备完成', 0)
    }).catch(async (error: Error): Promise<void> => {
      await abilityDelegatorRegistry.getAbilityDelegator().finishTest(`数据准备失败：${error.message}`, 1)
    })
  }
  private async run(): Promise<void> {
    const args = abilityDelegatorRegistry.getArguments()
    const moduleName = 'entry_test'
    try {
      // 运行器引用的共享 ArkTS 随测试包编译，资源 ID 归测试模块。
      const module = await application.createModuleContext(application.getApplicationContext(), moduleName)
      registerLocalizedResources(moduleName, module.resourceManager)
    } catch (error) { throw error as Error }
    const page = args.parameters['-s loadingPage']
    const calendarProbe = args.parameters['-s calendarProbe']
    if (typeof calendarProbe === 'string') return this.probeCalendar(calendarProbe)
    if (typeof page === 'string') return this.launchLoadingPage(page)
    return this.seed()
  }
  private async probeCalendar(mode: string): Promise<void> {
    try {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator()
      const monitor: EntryMonitor = { abilityName: 'EntryAbility' }
      await delegator.addAbilityMonitor(monitor)
      await delegator.startAbility({ bundleName: 'com.example.orgtasks', moduleName: 'entry', abilityName: 'EntryAbility',
        parameters: { httpApiEnabled: true } })
      const ability = await delegator.waitAbilityMonitor(monitor, 10000)
      if (mode === 'watch') {
        const stop = `${ability.context.filesDir}/calendar-probe-stop`
        if (await fs.access(stop)) await fs.unlink(stop)
        for (let count = 0; count < 480 && !await fs.access(stop); count++) {
          await probeCalendarReminders(ability.context, 'events')
          await new Promise<void>((resolve): void => { setTimeout(resolve, 500) })
        }
      } else await probeCalendarReminders(ability.context, mode)
    } catch (error) { throw error as Error }
  }
  private async launchLoadingPage(page: string): Promise<void> {
    try {
    const pages = ['Inbox', 'Today', 'Planned', 'Waiting', 'Anytime', 'Someday', 'Memo', 'Logbook', 'Trash', 'Files']
    if (!pages.includes(page)) throw new Error('不支持此读取状态页面')
    const delegator = abilityDelegatorRegistry.getAbilityDelegator()
    const filesDir = '/data/storage/el2/base/haps/entry/files'
    const repositories = (await fs.listFile(filesDir)).filter(name => /^notification-data-qa-[0-9]+$/.test(name))
    if (repositories.length !== 1) throw new Error('读取状态验收要求唯一的隔离模拟器仓库')
    const cache = `${filesDir}/page-data/v1`
    if (await fs.access(cache)) {
      for (const name of await fs.listFile(cache)) await fs.unlink(`${cache}/${name}`)
      await fs.rmdir(cache)
    }
    if (await fs.access(cache)) throw new Error('页面缓存未清空')
    const lock = await fs.open(`${filesDir}/${repositories[0]}/.sync/.transaction.lock`, fs.OpenMode.READ_ONLY)
    let locked = false
    try {
      lock.tryLock(true)
      locked = true
      await delegator.startAbility({ bundleName: 'com.example.orgtasks', moduleName: 'entry', abilityName: 'EntryAbility',
        parameters: { httpApiEnabled: true, httpApiPage: `pages/${page}` } })
      // 只延长真实仓库锁等待，页面与 Core 不加入验收专用延时。
      await new Promise<void>((resolve): void => { setTimeout(resolve, 3500) })
    } finally {
      if (locked) lock.unlock()
      await fs.close(lock)
    }
    // 保留界面供宿主采集加载完成后的布局和接口结果。
    await new Promise<void>((resolve): void => { setTimeout(resolve, 4500) })
    } catch (error) { throw error as Error }
  }
  private async seed(): Promise<void> {
    try {
    const delegator = abilityDelegatorRegistry.getAbilityDelegator()
    const monitor: EntryMonitor = { abilityName: 'EntryAbility' }
    await delegator.addAbilityMonitor(monitor)
    await delegator.startAbility({ bundleName: 'com.example.orgtasks', moduleName: 'entry', abilityName: 'EntryAbility' })
    const ability = await delegator.waitAbilityMonitor(monitor, 10000)
    const context = ability.context
    const projectData = abilityDelegatorRegistry.getArguments().parameters['-s projectData'] === 'true'
    const pageData = abilityDelegatorRegistry.getArguments().parameters['-s pageData'] === 'true'
    const notificationWebDav = abilityDelegatorRegistry.getArguments().parameters['-s notificationWebDav'] === 'true'
    const testDirectory = projectData ? `project-conversion-qa-${Date.now()}` : notificationWebDav || pageData ? `notification-data-qa-${Date.now()}` : 'today-data-qa'
    const directory = `${context.filesDir}/${testDirectory}`
    const today = localDate(new Date())
    const tomorrow = localDate(new Date(Date.now() + 86400000))
    if (!await fs.access(directory)) await fs.mkdir(directory, true)
    const source = `#+TITLE: 模拟器任务\n#+CATEGORY: 验证\n* TODO QA编辑\nSCHEDULED: <${today}>\n原备注\n* TODO QA联动\nSCHEDULED: <${today}>\n:PROPERTIES:\n:TRIGGER: next-sibling todo!(DONE)\n:END:\n* TODO QA关联\nSCHEDULED: <${today}>\n* TODO QA失败\nSCHEDULED: <${today}>\n:PROPERTIES:\n:TRIGGER: self todo!(INVALID)\n:END:\n* TODO QA随时\n原备注\n* TODO QA计划\nSCHEDULED: <${tomorrow}>\n原备注\n* TODO QA日程\nSCHEDULED: <${tomorrow} 10:00>\n原备注\n* DONE QA日志\nCLOSED: [${today} 09:00]\n:LOGBOOK:\n- State "DONE" from "TODO" [${today} 09:00]\n:END:\n`
    const habitSource = `* TODO QA今日习惯\nSCHEDULED: <${today} .+1d>\n:PROPERTIES:\n:STYLE: habit\n:END:\n* TODO QA未来习惯\nSCHEDULED: <${tomorrow} .+1d>\n:PROPERTIES:\n:STYLE: habit\n:END:\n`
    const file = await fs.open(`${directory}/tasks.org`, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
    try { await fs.write(file.fd, source + habitSource); await fs.fsync(file.fd) } finally { await fs.close(file) }
    const project = await fs.open(`${directory}/project.org`, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
    try { await fs.write(project.fd, '#+TITLE: 项目验收\n#+FILETAGS: :project:\n#+PROJECT_NAME: 项目验收\n#+CATEGORY: 验证\n#+TAGS: { product design }\n#+TAGS: { BUG FEAT } work home unused\n项目导言\n* 验收章节\n正文说明\n- 第一条普通列表\n  - 嵌套条目\n- 第二条普通列表\n** TODO QA项目 :product:\n原备注\n*** TODO QA子任务 :design:\n子任务备注\n** TODO QA叶任务 :design:\n叶任务正文只在展开后显示\n- 第一项\n- 第二项\n* 归档章节 :ARCHIVE:\n归档正文不应显示\n** TODO QA归档后代\n* 后续章节\n后续正文\n** TODO QA配置甲 :product:BUG:work:\n** TODO QA配置乙 :design:BUG:home:\n** TODO QA配置丙 :design:FEAT:work:\n'); await fs.fsync(project.fd) } finally { await fs.close(project) }
    const someday = await fs.open(`${directory}/someday.org`, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
    try { await fs.write(someday.fd, '#+TITLE: 某天验收\n* TODO QA某天\n原备注\n'); await fs.fsync(someday.fd) } finally { await fs.close(someday) }
    if (pageData) {
      const memo = await fs.open(`${directory}/memo.org`, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
      try { await fs.write(memo.fd, '#+TITLE: 备忘验收\n* QA备忘\n原备注\n'); await fs.fsync(memo.fd) } finally { await fs.close(memo) }
      const plain = await fs.open(`${directory}/plain.org`, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
      try { await fs.write(plain.fd, '#+TITLE: 普通文件验收\n* TODO QA普通文件\n原备注\n'); await fs.fsync(plain.fd) } finally { await fs.close(plain) }
    }
    const config = await AppConfigService.load(context, false)
    config.repos = [{ id: 'today-simulator-qa', name: '模拟器验证', rootDirectory: directory, webdavEnabled: notificationWebDav,
      webdavUrl: notificationWebDav ? `http://127.0.0.1:18789/${testDirectory}/` : '',
      webdavUsername: notificationWebDav ? 'qa' : '', webdavPassword: notificationWebDav ? 'qa' : '', excludedDirectories: [] }]
    if (projectData) {
      const targetDirectory = `${directory}-target`
      await fs.mkdir(targetDirectory, true)
      const setup = await fs.open(`${targetDirectory}/.setup.org`, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
      try { await fs.write(setup.fd, '#+TODO: TODO INPROGRESS | DONE\n'); await fs.fsync(setup.fd) } finally { await fs.close(setup) }
      config.repos.push({ id: 'project-target-qa', name: '项目目标', rootDirectory: targetDirectory,
        webdavEnabled: false, webdavUrl: '', webdavUsername: '', webdavPassword: '', excludedDirectories: [] })
    }
    config.inboxRepoId = 'today-simulator-qa'; config.inboxFile = 'tasks.org'
    config.somedayRepoId = 'today-simulator-qa'; config.somedayFile = 'someday.org'; config.memoRepoId = ''; config.memoFile = ''
    if (pageData) { config.memoRepoId = 'today-simulator-qa'; config.memoFile = 'memo.org' }
    if (notificationWebDav || projectData) config.todoDefaults = '#+TODO: TODO INPROGRESS | DONE'
    await AppConfigService.save(context, config)
    if (abilityDelegatorRegistry.getArguments().parameters['-s syncHistory'] === 'true') {
      if (!notificationWebDav) throw new Error('同步历史验收需要隔离的 WebDAV 仓库')
      const history = `${directory}/.sync/history`
      await fs.mkdir(history, true)
      const fixtures = [
        '{"id":"legacy-startup","kind":"webdav","started_at":1795100400000,"finished_at":1795100401000,"result":"Succeeded","trigger_reason":"appStartup","context_detail":{},"files":[]}',
        '{"id":"legacy-background","kind":"webdav","started_at":1795100402000,"finished_at":"bad","result":"Succeeded","trigger_reason":"appBackground","event":42,"files":[{"relative_path":"good.org","state":"Synchronized","action":"Downloaded"},{"relative_path":"bad.org","action":42}]}',
        '{'
      ]
      for (let index = 0; index < fixtures.length; index++) {
        const fixture = await fs.open(`${history}/${1795100400000 + index * 2000}.json`, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
        try { await fs.write(fixture.fd, fixtures[index]); await fs.fsync(fixture.fd) } finally { await fs.close(fixture) }
      }
    }
    if (notificationWebDav) {
      const request = RepositorySyncService.start(context, { source: 'manual', policy: SyncStartPolicy.Wait })
      if (request.kind === 'rejected') throw new Error('数据准备同步未被接受')
      const completion = await request.handle.completion
      if (completion.status !== 'succeeded') throw new Error(completion.message || '数据准备同步失败')
    }
    } catch (error) { throw error as Error }
  }
}
