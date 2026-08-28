import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  COLOR_CARD_BG,
  COLOR_PAGE_BG,
  COLOR_PRIMARY,
  COLOR_TEXT_CAPTION,
  COLOR_TEXT_PRIMARY
} from '../constants/AppTheme'

@Component
export struct StatCard {
  @Prop label: string = ''
  @Prop value: number = 0
  @Prop glyph: string = '·'
  @Prop accentColor: string = COLOR_PRIMARY

  build() {
    Column({ space: 8 }) {
      Row() {
        Text(this.glyph)
          .width(32)
          .height(32)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.accentColor)
          .textAlign(TextAlign.Center)
          .backgroundColor(COLOR_PAGE_BG)
          .borderRadius(16)

        Blank()

        Text(this.value.toString())
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TEXT_PRIMARY)
      }
      .width('100%')

      Text(this.label)
        .fontSize(BODY_FONT_SIZE)
        .fontColor(COLOR_TEXT_CAPTION)
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.SpaceBetween)
    .backgroundColor(COLOR_CARD_BG)
    .borderRadius(CARD_RADIUS)
  }
}
