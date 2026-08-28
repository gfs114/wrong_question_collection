import {
  BODY_FONT_SIZE,
  COLOR_PAGE_BG,
  COLOR_PRIMARY,
  COLOR_TEXT_CAPTION,
  COLOR_TEXT_PRIMARY,
  SUBTITLE_FONT_SIZE
} from '../constants/AppTheme'

@Component
export struct EmptyState {
  @Prop glyph: string = '·'
  @Prop title: string = ''
  @Prop description: string = ''
  @Prop actionLabel: string = ''
  @Prop showAction: boolean = false
  onAction: () => void = () => {
  }

  build() {
    Column({ space: 10 }) {
      Text(this.glyph)
        .width(64)
        .height(64)
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_PRIMARY)
        .textAlign(TextAlign.Center)
        .backgroundColor(COLOR_PAGE_BG)
        .borderRadius(32)

      Text(this.title)
        .fontSize(SUBTITLE_FONT_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_TEXT_PRIMARY)
        .textAlign(TextAlign.Center)

      Text(this.description)
        .fontSize(BODY_FONT_SIZE)
        .fontColor(COLOR_TEXT_CAPTION)
        .textAlign(TextAlign.Center)
        .lineHeight(22)

      if (this.showAction) {
        Button() {
          Text(this.actionLabel)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
        }
        .type(ButtonType.Normal)
        .height(48)
        .padding({ left: 24, right: 24 })
        .margin({ top: 10 })
        .backgroundColor(COLOR_PRIMARY)
        .borderRadius(16)
        .onClick(() => {
          this.onAction()
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 32, right: 32 })
    .justifyContent(FlexAlign.Center)
  }
}
