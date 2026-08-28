import {
  COLOR_PRIMARY,
  COLOR_TEXT_PRIMARY,
  PAGE_PADDING,
  TITLE_FONT_SIZE
} from '../constants/AppTheme'

@Component
export struct AppHeader {
  @Prop title: string = ''
  @Prop actionLabel: string = ''
  @Prop showAction: boolean = false
  @Prop showBack: boolean = false
  onAction: () => void = () => {
  }
  onBack: () => void = () => {
  }

  build() {
    Row() {
      if (this.showBack) {
        Button() {
          Text('‹')
            .fontSize(30)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_TEXT_PRIMARY)
        }
        .type(ButtonType.Normal)
        .width(48)
        .height(48)
        .padding(0)
        .margin({ right: 8 })
        .backgroundColor('#00000000')
        .borderRadius(24)
        .accessibilityText('返回')
        .onClick(() => {
          this.onBack()
        })
      }

      Text(this.title)
        .fontSize(TITLE_FONT_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_TEXT_PRIMARY)
        .maxLines(1)

      Blank()

      if (this.showAction) {
        Button() {
          Text(this.actionLabel)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
        }
        .type(ButtonType.Normal)
        .height(48)
        .padding({ left: 16, right: 16 })
        .backgroundColor(COLOR_PRIMARY)
        .borderRadius(14)
        .onClick(() => {
          this.onAction()
        })
      }
    }
    .width('100%')
    .height(76)
    .padding({ left: PAGE_PADDING, right: PAGE_PADDING })
  }
}
