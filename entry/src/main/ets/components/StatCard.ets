import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  themePalette
} from '../constants/AppTheme'
import { AppColors } from '../theme/AppColors'

@Component
export struct StatCard {
  @Prop label: string = ''
  @Prop value: number = 0
  @Prop glyph: string = '·'
  @Prop accentColor: string = ''
  @StorageProp('darkMode') darkMode: boolean = false

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

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
          .backgroundColor(this.colors().pageBackground)
          .borderRadius(16)

        Blank()

        Text(this.value.toString())
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.colors().textPrimary)
      }
      .width('100%')

      Text(this.label)
        .fontSize(BODY_FONT_SIZE)
        .fontColor(this.colors().textCaption)
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.SpaceBetween)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(CARD_RADIUS)
  }
}
