import { MapAppChoice } from '../services/ExternalLinkService'
import { UiColor } from '../ui/Theme'

@Builder
export function MapAppSheet(choices: MapAppChoice[], dismiss: () => void) {
  Column() {
    ForEach(choices, (choice: MapAppChoice) => {
      Text(choice.title).fontSize(22).fontColor(choice.installed ? UiColor.text : UiColor.secondary)
        .opacity(choice.installed ? 1 : 0.55).width('100%').textAlign(TextAlign.Center)
        .padding({ top: 20, bottom: 20 })
        .onClick((): void => { if (choice.installed) { dismiss(); choice.select() } })
    })
  }.width('100%').backgroundColor(UiColor.surface).borderRadius({ topLeft: 28, topRight: 28 })
}
