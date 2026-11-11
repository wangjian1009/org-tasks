import { MapAppChoice } from '../services/ExternalLinkService'
import { UiColor } from '../ui/Theme'

@Builder
export function MapAppSheet(choices: MapAppChoice[], dismiss: () => void, notify: (message: string) => void) {
  Column() {
    Text('选择地图').fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
      .width('100%').padding({ left: 24, top: 8, bottom: 4 })
      .textAlign(TextAlign.Start)
    if (choices.length > 0) {
      Text(choices[0].contextLabel).fontSize(14).fontColor(UiColor.secondary)
        .width('100%').padding({ left: 24, bottom: 10 }).textAlign(TextAlign.Start)
    }
    Divider().color(UiColor.divider).margin({ left: 24, right: 24 })
    ForEach(choices, (choice: MapAppChoice) => {
      Row({ space: 12 }) {
        Image(choice.icon).width(36).height(36).objectFit(ImageFit.Contain).borderRadius(8)
          .grayscale(choice.supported ? 0 : 1).opacity(choice.installed && choice.supported ? 1 : 0.5)
          .accessibilityLevel('no')
        Column({ space: 4 }) {
          Text(choice.title).fontSize(20).fontWeight(FontWeight.Medium)
            .fontColor(choice.installed && choice.supported ? UiColor.text : UiColor.disabled)
          Text(choice.description).fontSize(14).fontColor(UiColor.secondary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        if (choice.installed && choice.supported) {
          Image($r('app.media.ui_next')).width(24).height(24).fillColor(UiColor.primary).accessibilityLevel('no')
        }
      }.width('100%').padding({ left: 24, right: 24, top: 12, bottom: 12 })
        .onClick((): void => {
          if (!choice.installed) { notify('未安装此地图应用。'); return }
          if (!choice.supported) { notify(choice.unsupportedMessage || '此地图应用不支持当前地址。'); return }
          dismiss(); choice.select()
        })
    })
  }.width('100%').backgroundColor(UiColor.surface).borderRadius({ topLeft: 28, topRight: 28 })
}
