import { router } from '@kit.ArkUI'
import { preferences } from '@kit.ArkData'

const SEARCH_PREFERENCES = 'org_tasks_saved_searches'

interface SavedSearch {
  id: string
  name: string
  query: string
}

interface SavedSearchParams {
  query?: string
}

@Entry
@Component
struct SavedSearches {
  @State searches: SavedSearch[] = []
  @State query: string = ''
  @State name: string = ''
  @State editing: boolean = false
  @State message: string = ''

  aboutToAppear() {
    const params = router.getParams() as SavedSearchParams | undefined
    this.query = params?.query || ''
    this.loadSearches()
  }

  async loadSearches() {
    try {
      const store = await preferences.getPreferences(getContext(this), SEARCH_PREFERENCES)
      const value = await store.get('items', '[]') as string
      this.searches = JSON.parse(value) as SavedSearch[]
    } catch (e) {
      this.message = `读取已保存搜索失败: ${JSON.stringify(e)}`
    }
  }

  async persistSearches() {
    const store = await preferences.getPreferences(getContext(this), SEARCH_PREFERENCES)
    await store.put('items', JSON.stringify(this.searches))
    await store.flush()
  }

  async saveSearch() {
    if (!this.name.trim()) {
      this.message = '请输入搜索名称'
      return
    }
    const search: SavedSearch = {
      id: Date.now().toString(),
      name: this.name.trim(),
      query: this.query.trim()
    }
    this.searches = [search, ...this.searches]
    await this.persistSearches()
    this.name = ''
    this.editing = false
    this.message = '搜索已保存'
  }

  async removeSearch(id: string) {
    this.searches = this.searches.filter((item: SavedSearch) => item.id !== id)
    await this.persistSearches()
  }

  openSearch(search: SavedSearch) {
    router.pushUrl({ url: 'pages/Search', params: { query: search.query } })
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
          Text('已保存搜索')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
          Text('保留常用的任务筛选')
            .fontSize(12)
            .fontColor('#65746B')
            .margin({ top: 2 })
        }
        .margin({ left: 12 })
        .layoutWeight(1)
        Button(this.editing ? '收起' : '新建')
          .fontSize(14)
          .backgroundColor('#F2EDF9')
          .fontColor('#6A4C93')
          .onClick(() => this.editing = !this.editing)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 14 })

      if (this.editing) {
        Column() {
          Text('保存筛选')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
          TextInput({ placeholder: '名称，例如：本周重点', text: this.name })
            .height(42)
            .backgroundColor('#FFFFFF')
            .margin({ top: 10 })
            .onChange((value: string) => this.name = value)
          TextInput({ placeholder: '搜索关键词（可为空）', text: this.query })
            .height(42)
            .backgroundColor('#FFFFFF')
            .margin({ top: 8 })
            .onChange((value: string) => this.query = value)
          Button('保存搜索')
            .width('100%')
            .height(40)
            .margin({ top: 10 })
            .backgroundColor('#6A4C93')
            .onClick(() => this.saveSearch())
        }
        .width('100%')
        .backgroundColor('#EEE9F5')
        .padding(16)
        .margin({ left: 20, right: 20, bottom: 12 })
      }

      if (this.message) {
        Text(this.message)
          .fontSize(13)
          .fontColor(this.message.includes('失败') ? '#B3261E' : '#357A55')
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 10 })
      }

      if (this.searches.length === 0) {
        Column() {
          Text('还没有已保存搜索')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
          Text('从搜索页保存当前关键词，或在这里新建筛选。')
            .fontSize(13)
            .fontColor('#65746B')
            .margin({ top: 8 })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 1 }) {
          ForEach(this.searches, (search: SavedSearch) => {
            ListItem() {
              Row() {
                Column() {
                  Text(search.name)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                  Text(search.query || '全部任务')
                    .fontSize(13)
                    .fontColor('#65746B')
                    .margin({ top: 5 })
                }
                .layoutWeight(1)
                Button('打开')
                  .fontSize(12)
                  .backgroundColor('#FFFFFF')
                  .fontColor('#6A4C93')
                  .onClick(() => this.openSearch(search))
                Button('删除')
                  .fontSize(12)
                  .backgroundColor('#FFFFFF')
                  .fontColor('#B3261E')
                  .margin({ left: 4 })
                  .onClick(() => this.removeSearch(search.id))
              }
              .width('100%')
              .padding({ left: 20, right: 14, top: 14, bottom: 14 })
              .backgroundColor('#FFFFFF')
            }
          }, (search: SavedSearch) => search.id)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F7F8F7')
  }
}
