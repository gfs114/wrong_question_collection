import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  themePalette
} from '../constants/AppTheme'
import { AppColors } from '../theme/AppColors'

@Component
export struct WrongQuestionCard {
  @Prop subject: string = ''
  @Prop bankName: string = ''
  @Prop questionText: string = ''
  @Prop mastered: boolean = false
  @Prop addTimeText: string = ''
  @StorageProp('darkMode') darkMode: boolean = false
  onOpen: () => void = () => {
  }

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  build() {
    Button() {
      Column({ space: 12 }) {
        Row({ space: 8 }) {
          Text(this.subject)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().textPrimary)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor(this.colors().pageBackground)
            .borderRadius(12)

          Text(this.mastered ? '已掌握' : '待复习')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.mastered ? this.colors().successText : this.colors().textCaption)

          Blank()
        }
        .width('100%')

        Text(this.questionText)
          .width('100%')
          .fontSize(BODY_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
          .maxLines(3)

        Row() {
          Text(this.bankName)
            .fontSize(12)
            .fontColor(this.colors().textCaption)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          Text(this.addTimeText)
            .fontSize(12)
            .fontColor(this.colors().textCaption)
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
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(CARD_RADIUS)
    .onClick(() => {
      this.onOpen()
    })
  }
}
