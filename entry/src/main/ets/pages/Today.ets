import { TaskPageContent } from '../components/TaskPageContent'

@Entry({ useSharedStorage: true })
@Component
struct Today {
  build() {
    Stack() {
      TaskPageContent({ view: 'today', pageRoute: 'pages/Today' })
    }
  }
}
