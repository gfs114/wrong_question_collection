import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  themePalette
} from '../constants/AppTheme'
import { AppColors } from '../theme/AppColors'

@Component
export struct QuestionCard {
  @Prop sequence: number = 0
  @Prop typeLabel: string = ''
  @Prop questionText: string = ''
  @Prop needsReview: boolean = false
  @StorageProp('darkMode') darkMode: boolean = false
  onOpen: () => void = () => {
  }

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  build() {
    Button() {
      Row({ space: 14 }) {
        Text(this.sequence.toString())
          .width(40)
          .height(40)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.colors().brand)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.colors().pageBackground)
          .borderRadius(20)

        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Text(this.typeLabel)
              .fontSize(12)
              .fontColor(this.colors().textCaption)

            if (this.needsReview) {
              Text('待确认')
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.colors().warningText)
                .backgroundColor(this.colors().warning)
                .borderRadius(9)
            }
          }
          .width('100%')

          Text(this.questionText)
            .fontSize(BODY_FONT_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().textPrimary)
            .maxLines(3)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text('›')
          .fontSize(24)
          .fontColor(this.colors().brand)
      }
      .width('100%')
      .padding(18)
    }
    .type(ButtonType.Normal)
    .width('100%')
    .padding(0)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(CARD_RADIUS)
    .onClick(() => {
      this.onOpen()
    })
  }
}
