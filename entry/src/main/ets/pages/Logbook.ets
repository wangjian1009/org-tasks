import { TaskPageContent } from '../components/TaskPageContent'

@Entry({ useSharedStorage: true })
@Component
struct Logbook {
  build() {
    Stack() {
      TaskPageContent({ view: 'logbook', pageRoute: 'pages/Logbook' })
    }
  }
}
