import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  COLOR_CARD_BG,
  COLOR_DANGER,
  COLOR_PAGE_BG,
  COLOR_PRIMARY,
  COLOR_TEXT_CAPTION,
  COLOR_TEXT_PRIMARY,
  SUBTITLE_FONT_SIZE
} from '../constants/AppTheme'

@Component
export struct QuestionBankCard {
  @Prop bankName: string = ''
  @Prop subject: string = ''
  @Prop questionCount: number = 0
  @Prop createDate: string = ''
  @Prop deleting: boolean = false
  onOpen: () => void = () => {
  }
  onDelete: () => void = () => {
  }

  build() {
    Column() {
      Button() {
        Row() {
          Column({ space: 7 }) {
            Text(this.bankName)
              .fontSize(SUBTITLE_FONT_SIZE)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLOR_TEXT_PRIMARY)
              .maxLines(2)

            Text(this.questionCount.toString() + ' 道题')
              .fontSize(BODY_FONT_SIZE)
              .fontColor(COLOR_TEXT_CAPTION)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text('›')
            .fontSize(28)
            .fontColor(COLOR_PRIMARY)
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 18, bottom: 12 })
      }
      .type(ButtonType.Normal)
      .width('100%')
      .padding(0)
      .backgroundColor(COLOR_CARD_BG)
      .enabled(!this.deleting)
      .accessibilityText('打开题库：' + this.bankName)
      .onClick(() => {
        this.onOpen()
      })

      Row({ space: 10 }) {
        Text(this.subject)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_PRIMARY)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(COLOR_PAGE_BG)
          .borderRadius(12)

        Text(this.createDate)
          .fontSize(12)
          .fontColor(COLOR_TEXT_CAPTION)

        Blank()

        Button() {
          Text('删除')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_DANGER)
        }
        .type(ButtonType.Normal)
        .width(56)
        .height(48)
        .padding(0)
        .backgroundColor(COLOR_PAGE_BG)
        .borderRadius(14)
        .enabled(!this.deleting)
        .accessibilityText('删除题库：' + this.bankName)
        .onClick(() => {
          this.onDelete()
        })
      }
      .width('100%')
      .height(56)
      .padding({ left: 18, right: 10, bottom: 8 })
    }
    .width('100%')
    .backgroundColor(COLOR_CARD_BG)
    .borderRadius(CARD_RADIUS)
  }
}
