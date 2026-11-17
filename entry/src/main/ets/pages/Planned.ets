import { TaskPageContent } from '../components/TaskPageContent'

@Entry({ useSharedStorage: true })
@Component
struct Planned {
  build() {
    Stack() {
      TaskPageContent({ view: 'planned', pageRoute: 'pages/Planned' })
    }
  }
}
