import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  SUBTITLE_FONT_SIZE,
  themePalette
} from '../constants/AppTheme'
import { AppColors } from '../theme/AppColors'
import { QuestionImage } from '../models/QuestionImage'

@Component
export struct QuestionSourceImages {
  @Prop images: Array<QuestionImage> = new Array<QuestionImage>()
  @StorageProp('darkMode') darkMode: boolean = false

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  build() {
    Column() {
      if (this.images.length > 0) {
        Column({ space: 12 }) {
          Text('原题图片')
            .width('100%')
            .fontSize(SUBTITLE_FONT_SIZE)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors().textPrimary)

          ForEach(this.images, (image: QuestionImage) => {
            Image('file://' + image.imagePath)
              .width('100%')
              .objectFit(ImageFit.Contain)
              .borderRadius(12)
          }, (image: QuestionImage): string => image.id)

          Text('图片仅用于核对原题，编辑不会改动源图。')
            .width('100%')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().textCaption)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(20)
        .backgroundColor(this.colors().cardBackground)
        .borderRadius(CARD_RADIUS)
      }
    }
    .width('100%')
  }
}
