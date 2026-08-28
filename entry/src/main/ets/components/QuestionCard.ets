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
export struct QuestionCard {
  @Prop sequence: number = 0
  @Prop typeLabel: string = ''
  @Prop questionText: string = ''
  @Prop needsReview: boolean = false
  onOpen: () => void = () => {
  }

  build() {
    Button() {
      Row({ space: 14 }) {
        Text(this.sequence.toString())
          .width(40)
          .height(40)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_PRIMARY)
          .textAlign(TextAlign.Center)
          .backgroundColor(COLOR_PAGE_BG)
          .borderRadius(20)

        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Text(this.typeLabel)
              .fontSize(12)
              .fontColor(COLOR_TEXT_CAPTION)

            if (this.needsReview) {
              Text('待确认')
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor('#9A5A00')
                .backgroundColor('#FFF1D6')
                .borderRadius(9)
            }
          }
          .width('100%')

          Text(this.questionText)
            .fontSize(BODY_FONT_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_TEXT_PRIMARY)
            .maxLines(3)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text('›')
          .fontSize(24)
          .fontColor(COLOR_PRIMARY)
      }
      .width('100%')
      .padding(18)
    }
    .type(ButtonType.Normal)
    .width('100%')
    .padding(0)
    .backgroundColor(COLOR_CARD_BG)
    .borderRadius(CARD_RADIUS)
    .onClick(() => {
      this.onOpen()
    })
  }
}
