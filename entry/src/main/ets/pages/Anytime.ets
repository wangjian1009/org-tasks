import { TaskPageContent } from '../components/TaskPageContent'

@Entry({ useSharedStorage: true })
@Component
struct Anytime {
  build() {
    Stack() {
      TaskPageContent({ view: 'anytime', pageRoute: 'pages/Anytime' })
    }
  }
}
