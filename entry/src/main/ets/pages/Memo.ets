import { TaskPageContent } from '../components/TaskPageContent'

@Entry({ useSharedStorage: true })
@Component
struct Memo {
  build() {
    Stack() {
      TaskPageContent({ view: 'memo', pageRoute: 'pages/Memo' })
    }
  }
}
