import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  SUBTITLE_FONT_SIZE,
  themePalette
} from '../constants/AppTheme'
import { AppColors } from '../theme/AppColors'

@Component
export struct QuestionBankCard {
  @Prop bankName: string = ''
  @Prop subject: string = ''
  @Prop questionCount: number = 0
  @Prop createDate: string = ''
  @Prop deleting: boolean = false
  @StorageProp('darkMode') darkMode: boolean = false
  onOpen: () => void = () => {
  }
  onDelete: () => void = () => {
  }

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  build() {
    Column() {
      Button() {
        Row() {
          Column({ space: 7 }) {
            Text(this.bankName)
              .fontSize(SUBTITLE_FONT_SIZE)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.colors().textPrimary)
              .maxLines(2)

            Text(this.questionCount.toString() + ' 道题')
              .fontSize(BODY_FONT_SIZE)
              .fontColor(this.colors().textCaption)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text('›')
            .fontSize(28)
            .fontColor(this.colors().brand)
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 18, bottom: 12 })
      }
      .type(ButtonType.Normal)
      .width('100%')
      .padding(0)
      .backgroundColor(this.colors().cardBackground)
      .enabled(!this.deleting)
      .accessibilityText('打开题库：' + this.bankName)
      .onClick(() => {
        this.onOpen()
      })

      Row({ space: 10 }) {
        Text(this.subject)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().brand)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.colors().pageBackground)
          .borderRadius(12)

        Text(this.createDate)
          .fontSize(12)
          .fontColor(this.colors().textCaption)

        Blank()

        Button() {
          Text('删除')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().error)
        }
        .type(ButtonType.Normal)
        .width(56)
        .height(48)
        .padding(0)
        .backgroundColor(this.colors().pageBackground)
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
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(CARD_RADIUS)
  }
}
