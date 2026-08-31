import { router } from '@kit.ArkUI'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { FileService, OrgFileInfo } from '../services/FileService'
import { WebDavCachedFile, WebDavService } from '../services/WebDavService'
import { AppConfigService } from '../services/AppConfigService'

interface FileRow extends OrgFileInfo {
  status: 'synced' | 'pending' | 'local'
}

interface FileRouteParams {
  path: string
}

@Entry
@Component
struct Files {
  @State files: FileRow[] = []
  @State filter: string = 'all'
  @State refreshing: boolean = false
  @State message: string = ''
  @State config: AppConfig = DEFAULT_CONFIG

  aboutToAppear() {
    this.loadConfigAndFiles()
  }

  async loadConfigAndFiles() {
    try {
      const context = getContext(this)
      this.config = await AppConfigService.load(context)
      this.loadCachedFiles()
    } catch (e) {
      this.message = `读取文件列表失败: ${JSON.stringify(e)}`
    }
  }

  loadCachedFiles() {
    if (this.config.webdavEnabled) {
      const cached: WebDavCachedFile[] = new WebDavService(getContext(this), this.config).getCachedFiles()
      const rows: FileRow[] = []
      for (const file of cached) {
        rows.push({
          relativePath: file.relativePath,
          localMtime: file.localMtime,
          taskCount: file.taskCount,
          status: file.status
        })
      }
      this.files = rows
      this.message = rows.length > 0 ? '显示上次 WebDAV 同步的缓存' : '尚无缓存，点击刷新下载文件'
      return
    }

    const rows: FileRow[] = []
    for (const file of FileService.listOrgFiles(this.config.orgDir)) {
      rows.push({ relativePath: file.relativePath, localMtime: file.localMtime, taskCount: file.taskCount, status: 'local' })
    }
    this.files = rows
    this.message = rows.length > 0 ? '显示本地目录中的 org 文件' : '未找到 org 文件'
  }

  async refresh() {
    if (this.refreshing) return
    this.refreshing = true
    if (this.config.webdavEnabled) {
      this.message = '正在刷新 WebDAV 文件...'
      const result = await new WebDavService(getContext(this), this.config).syncToCache()
      if (!result.ok) {
        this.message = `刷新失败: ${result.message}`
        this.refreshing = false
        return
      }
    }
    this.loadCachedFiles()
    this.refreshing = false
  }

  visibleFiles(): FileRow[] {
    if (this.filter === 'pending') return this.files.filter((file: FileRow) => file.status === 'pending')
    if (this.filter === 'synced') return this.files.filter((file: FileRow) => file.status !== 'pending')
    return this.files
  }

  statusLabel(status: string): string {
    if (status === 'pending') return '待上传'
    if (status === 'local') return '本地'
    return '已同步'
  }

  statusColor(status: string): string {
    if (status === 'pending') return '#F57C00'
    if (status === 'local') return '#607D8B'
    return '#2E7D32'
  }

  formatTime(timestamp: number): string {
    if (timestamp <= 0) return '未知时间'
    const date = new Date(timestamp)
    return `${date.getMonth() + 1}/${date.getDate()} ${date.getHours()}:${date.getMinutes().toString().padStart(2, '0')}`
  }

  openFile(file: FileRow) {
    const params: FileRouteParams = { path: file.relativePath }
    router.pushUrl({ url: 'pages/FileDetail', params })
  }

  build() {
    Column() {
      Row() {
        Button('返回')
          .fontSize(14)
          .onClick(() => router.back())
        Text('文件')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 12 })
        Blank()
        Button(this.refreshing ? '刷新中...' : '刷新')
          .fontSize(14)
          .enabled(!this.refreshing)
          .onClick(() => this.refresh())
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 12 })

      Text(`${this.files.length} 个文件${this.config.webdavEnabled ? ' · WebDAV 缓存' : ' · 本地目录'}`)
        .fontSize(14)
        .fontColor('#666')
        .width('100%')
        .padding({ left: 20, right: 20 })

      Row() {
        Button('全部').fontSize(13).backgroundColor(this.filter === 'all' ? '#1976D2' : '#E0E0E0').onClick(() => this.filter = 'all')
        Button('已同步').fontSize(13).backgroundColor(this.filter === 'synced' ? '#1976D2' : '#E0E0E0').margin({ left: 8 }).onClick(() => this.filter = 'synced')
        Button('待上传').fontSize(13).backgroundColor(this.filter === 'pending' ? '#1976D2' : '#E0E0E0').margin({ left: 8 }).onClick(() => this.filter = 'pending')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 8 })

      if (this.message) {
        Text(this.message)
          .fontSize(13)
          .fontColor(this.message.includes('失败') ? '#C62828' : '#666')
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 8 })
      }

      List({ space: 1 }) {
        ForEach(this.visibleFiles(), (file: FileRow) => {
          ListItem() {
            Row() {
              Column() {
                Text(file.relativePath)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${file.taskCount} 个任务 · ${this.formatTime(file.localMtime)}`)
                  .fontSize(12)
                  .fontColor('#777')
                  .margin({ top: 4 })
              }
              .layoutWeight(1)
              Text(this.statusLabel(file.status))
                .fontSize(12)
                .fontColor(this.statusColor(file.status))
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 14, bottom: 14 })
            .backgroundColor('#FFFFFF')
            .onClick(() => this.openFile(file))
          }
        }, (file: FileRow) => file.relativePath)
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}
