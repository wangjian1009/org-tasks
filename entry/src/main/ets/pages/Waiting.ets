import { TaskPageContent } from '../components/TaskPageContent'

@Entry({ useSharedStorage: true })
@Component
struct Waiting {
  build() {
    Stack() {
      TaskPageContent({ view: 'waiting', pageRoute: 'pages/Waiting' })
    }
  }
}
