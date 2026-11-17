import { TaskPageContent } from '../components/TaskPageContent'
import { PageNavigator } from '../services/PageNavigator'

@Entry({ useSharedStorage: true })
@Component
struct Today {
  onBackPress(): boolean { PageNavigator.shared.back(this.getUIContext()); return true }

  build() {
    Stack() {
      TaskPageContent({ view: 'today', pageRoute: 'pages/Today' })
    }
  }
}
