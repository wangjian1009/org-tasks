import { router } from '@kit.ArkUI'
import { preferences } from '@kit.ArkData'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { FileService } from '../services/FileService'
import { CredentialService } from '../services/CredentialService'
import { OrgParser } from '../services/OrgParser'
import { WebDavService } from '../services/WebDavService'

const PREF_NAME = 'org_tasks_config'

interface FileDetailParams {
  path?: string
}

@Entry
@Component
struct FileDetail {
  @State path: string = ''
  @State content: string = ''
  @State taskCount: number = 0
  @State mtime: number = 0
  @State message: string = ''

  aboutToAppear() {
    this.loadFile()
  }

  async loadFile() {
    const params = router.getParams() as FileDetailParams
    this.path = params.path || ''
    if (!this.isSafeFileName(this.path)) {
      this.message = '无效的文件路径'
      return
    }

    try {
      const context = getContext(this)
      const store = await preferences.getPreferences(context, PREF_NAME)
      const orgDir = await store.get('orgDir', DEFAULT_CONFIG.orgDir) as string
      const inboxFile = await store.get('inboxFile', DEFAULT_CONFIG.inboxFile) as string
      const calendarName = await store.get('calendarName', DEFAULT_CONFIG.calendarName) as string
      const syncInterval = await store.get('syncInterval', DEFAULT_CONFIG.syncInterval) as number
      const webdavEnabled = await store.get('webdavEnabled', DEFAULT_CONFIG.webdavEnabled) as boolean
      const webdavUrl = await store.get('webdavUrl', DEFAULT_CONFIG.webdavUrl) as string
      const webdavUsername = await store.get('webdavUsername', DEFAULT_CONFIG.webdavUsername) as string
      const webdavPassword = await CredentialService.getWebDavPassword(context)
      const config: AppConfig = { orgDir, inboxFile, calendarName, syncInterval, webdavEnabled, webdavUrl, webdavUsername, webdavPassword }
      const sourceDir = webdavEnabled ? new WebDavService(context, config).getLocalDir() : orgDir
      this.content = webdavEnabled
        ? new WebDavService(context, config).readCachedFile(this.path)
        : FileService.readFileIfExists(`${sourceDir}/${this.path}`)
      if (!this.content) {
        this.message = '缓存中未找到此文件'
        return
      }
      this.taskCount = OrgParser.parse(this.content, `${sourceDir}/${this.path}`).length
      this.mtime = FileService.getMtime(`${sourceDir}/${this.path}`)
    } catch (e) {
      this.message = `读取文件失败: ${JSON.stringify(e)}`
    }
  }

  isSafeFileName(value: string): boolean {
    return value.length > 0 && !value.includes('/') && !value.includes('\\') && !value.includes('..')
  }

  formatTime(timestamp: number): string {
    if (timestamp <= 0) return '未知时间'
    const date = new Date(timestamp)
    return `${date.getFullYear()}-${(date.getMonth() + 1).toString().padStart(2, '0')}-${date.getDate().toString().padStart(2, '0')} ${date.getHours()}:${date.getMinutes().toString().padStart(2, '0')}`
  }

  build() {
    Column() {
      Row() {
        Button('返回')
          .fontSize(14)
          .onClick(() => router.back())
        Text(this.path || '文件详情')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 12 })
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 12 })

      if (this.message) {
        Text(this.message)
          .fontSize(14)
          .fontColor('#C62828')
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 12 })
      } else {
        Text(`${this.taskCount} 个任务 · ${this.formatTime(this.mtime)}`)
          .fontSize(13)
          .fontColor('#666')
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 12 })
        Scroll() {
          Text(this.content)
            .fontSize(14)
            .fontFamily('monospace')
            .fontColor('#333')
            .width('100%')
            .padding(16)
        }
        .layoutWeight(1)
        .backgroundColor('#FFFFFF')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}
