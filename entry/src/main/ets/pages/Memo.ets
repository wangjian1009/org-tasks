import { TaskPageContent } from '../components/TaskPageContent'
import { PageNavigator } from '../services/PageNavigator'

@Entry({ useSharedStorage: true })
@Component
struct Memo {
  onBackPress(): boolean { PageNavigator.shared.back(this.getUIContext()); return true }

  build() {
    Stack() {
      TaskPageContent({ view: 'memo', pageRoute: 'pages/Memo' })
    }
  }
}
