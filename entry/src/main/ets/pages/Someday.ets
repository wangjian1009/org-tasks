import { TaskPageContent } from '../components/TaskPageContent'

@Entry({ useSharedStorage: true })
@Component
struct Someday {
  build() {
    Stack() {
      TaskPageContent({ view: 'someday', pageRoute: 'pages/Someday' })
    }
  }
}
