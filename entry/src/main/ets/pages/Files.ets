import { router } from '@kit.ArkUI'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
import { CoreTask, CoreWebDavSyncEvent, NativeCoreService } from '../services/NativeCoreService'

interface FileRow {
  relativePath: string
  source: string
  byteLength: number
  taskCount: number
  tasks: CoreTask[]
}

interface FileRouteParams {
  path: string
  source: string
  tasks: CoreTask[]
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
      await this.loadWorkspace()
    } catch (e) {
      this.message = `读取文件列表失败: ${JSON.stringify(e)}`
    }
  }

  async loadWorkspace() {
    const response = await NativeCoreService.loadWorkspace(this.config.orgDir)
    const rows: FileRow[] = []
    for (const repo of response.workspace.repos) {
      for (const file of repo.files) {
        const tasks = response.tasks.filter((task: CoreTask) => task.filePath === file.path)
        rows.push({
          relativePath: file.path,
          source: file.source,
          byteLength: file.byte_length,
          taskCount: tasks.length,
          tasks
        })
      }
    }
    this.files = rows
    this.message = rows.length > 0 ? '显示 core workspace 文件快照' : 'workspace 中未找到 org 文件'
  }

  async refresh() {
    if (this.refreshing) return
    this.refreshing = true
    try {
      this.message = this.config.webdavEnabled ? '正在通过 core 同步 WebDAV...' : '正在通过 core 加载 workspace...'
      if (this.config.webdavEnabled) {
        await NativeCoreService.syncWorkspaceWebDav(
          this.config.orgDir,
          this.config.webdavUrl,
          this.config.webdavUsername,
          this.config.webdavPassword,
          (event: CoreWebDavSyncEvent) => this.updateWebDavProgress(event)
        )
      }
      await this.loadWorkspace()
    } catch (e) {
      this.message = `刷新失败: ${JSON.stringify(e)}`
    } finally {
      this.refreshing = false
    }
  }

  visibleFiles(): FileRow[] {
    return this.files
  }

  private updateWebDavProgress(event: CoreWebDavSyncEvent) {
    switch (event.type) {
      case 'listingStarted':
        this.message = '正在读取 WebDAV 文件列表...'
        break
      case 'fileStarted':
        this.message = `正在同步 ${event.index + 1}/${event.total}: ${event.path}`
        break
      case 'fileProcessed':
        this.message = `已处理 ${event.path}`
        break
      case 'finished':
        this.message = `WebDAV 同步${event.result === 'succeeded' ? '完成' : '结束'}，共 ${event.files} 个文件`
        break
    }
  }

  openFile(file: FileRow) {
    const params: FileRouteParams = { path: file.relativePath, source: file.source, tasks: file.tasks }
    router.pushUrl({ url: 'pages/FileDetail', params })
  }

  build() {
    Column() {
      Row() {
        Button('工作区')
          .fontSize(14)
          .backgroundColor('#FFFFFF')
          .fontColor('#34423B')
          .onClick(() => router.pushUrl({ url: 'pages/Workspace' }))
        Column() {
          Text('笔记本')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
          Text('org 文件与任务层级')
            .fontSize(12)
            .fontColor('#65746B')
            .margin({ top: 2 })
        }
        .margin({ left: 12 })
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 12 })

      Text(`${this.files.length} 个文件 · core workspace`)
        .fontSize(14)
        .fontColor('#666')
        .width('100%')
        .padding({ left: 20, right: 20 })

      Row() {
        Button(this.refreshing ? '刷新中...' : '刷新文件')
          .width('100%')
          .height(40)
          .margin({ left: 8 })
          .backgroundColor('#FFF3E5')
          .fontColor('#7A4D16')
          .enabled(!this.refreshing)
          .onClick(() => this.refresh())
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12 })

      Row() {
        Button('全部').fontSize(13).backgroundColor(this.filter === 'all' ? '#7A4D16' : '#FFFFFF').fontColor(this.filter === 'all' ? '#FFFFFF' : '#34423B').onClick(() => this.filter = 'all')
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
                Text(`${file.taskCount} 个任务 · ${file.byteLength} 字节`)
                  .fontSize(12)
                  .fontColor('#777')
                  .margin({ top: 4 })
              }
              .layoutWeight(1)
              Text('已加载')
                .fontSize(12)
                .fontColor('#2E7D32')
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
    .backgroundColor('#F7F8F7')
  }
}
