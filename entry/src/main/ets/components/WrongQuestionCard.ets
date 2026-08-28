import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  COLOR_CARD_BG,
  COLOR_PAGE_BG,
  COLOR_SUCCESS_TEXT,
  COLOR_TEXT_CAPTION,
  COLOR_TEXT_PRIMARY
} from '../constants/AppTheme'

@Component
export struct WrongQuestionCard {
  @Prop subject: string = ''
  @Prop bankName: string = ''
  @Prop questionText: string = ''
  @Prop mastered: boolean = false
  @Prop addTimeText: string = ''
  onOpen: () => void = () => {
  }

  build() {
    Button() {
      Column({ space: 12 }) {
        Row({ space: 8 }) {
          Text(this.subject)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_TEXT_PRIMARY)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor(COLOR_PAGE_BG)
            .borderRadius(12)

          Text(this.mastered ? '已掌握' : '待复习')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.mastered ? COLOR_SUCCESS_TEXT : COLOR_TEXT_CAPTION)

          Blank()
        }
        .width('100%')

        Text(this.questionText)
          .width('100%')
          .fontSize(BODY_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_TEXT_PRIMARY)
          .maxLines(3)

        Row() {
          Text(this.bankName)
            .fontSize(12)
            .fontColor(COLOR_TEXT_CAPTION)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          Text(this.addTimeText)
            .fontSize(12)
            .fontColor(COLOR_TEXT_CAPTION)
            .margin({ left: 12 })
        }
        .width('100%')
      }
      .width('100%')
      .padding(18)
      .alignItems(HorizontalAlign.Start)
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
