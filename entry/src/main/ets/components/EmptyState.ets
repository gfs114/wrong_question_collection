import {
  BODY_FONT_SIZE,
  SUBTITLE_FONT_SIZE,
  themePalette
} from '../constants/AppTheme'
import { AppColors } from '../theme/AppColors'

@Component
export struct EmptyState {
  @Prop glyph: string = '·'
  @Prop title: string = ''
  @Prop description: string = ''
  @Prop actionLabel: string = ''
  @Prop showAction: boolean = false
  @StorageProp('darkMode') darkMode: boolean = false
  onAction: () => void = () => {
  }

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  build() {
    Column({ space: 10 }) {
      Text(this.glyph)
        .width(64)
        .height(64)
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.colors().brand)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.colors().pageBackground)
        .borderRadius(32)

      Text(this.title)
        .fontSize(SUBTITLE_FONT_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.colors().textPrimary)
        .textAlign(TextAlign.Center)

      Text(this.description)
        .fontSize(BODY_FONT_SIZE)
        .fontColor(this.colors().textCaption)
        .textAlign(TextAlign.Center)
        .lineHeight(22)

      if (this.showAction) {
        Button() {
          Text(this.actionLabel)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().onBrand)
        }
        .type(ButtonType.Normal)
        .height(48)
        .padding({ left: 24, right: 24 })
        .margin({ top: 10 })
        .backgroundColor(this.colors().brand)
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
