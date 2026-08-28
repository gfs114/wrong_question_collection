import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  COLOR_CARD_BG,
  COLOR_TEXT_PRIMARY,
  SUBTITLE_FONT_SIZE
} from '../constants/AppTheme'
import { QuestionImage } from '../models/QuestionImage'

@Component
export struct QuestionSourceImages {
  @Prop images: Array<QuestionImage> = new Array<QuestionImage>()

  build() {
    Column() {
      if (this.images.length > 0) {
        Column({ space: 12 }) {
          Text('原题图片')
            .width('100%')
            .fontSize(SUBTITLE_FONT_SIZE)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLOR_TEXT_PRIMARY)

          ForEach(this.images, (image: QuestionImage) => {
            Image('file://' + image.imagePath)
              .width('100%')
              .objectFit(ImageFit.Contain)
              .borderRadius(12)
          }, (image: QuestionImage): string => image.id)

          Text('图片仅用于核对原题，编辑不会改动源图。')
            .width('100%')
            .fontSize(BODY_FONT_SIZE)
            .fontColor('#536077')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(20)
        .backgroundColor(COLOR_CARD_BG)
        .borderRadius(CARD_RADIUS)
      }
    }
    .width('100%')
  }
}
