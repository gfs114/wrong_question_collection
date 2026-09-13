import {
  BADGE_RADIUS,
  HAIRLINE,
  SHEET_RADIUS
} from '../constants/EditorialStyle'
import {
  BODY_FONT_SIZE,
  SUBTITLE_FONT_SIZE,
  themePalette
} from '../constants/AppTheme'
import { AppColors } from '../theme/AppColors'

/**
 * 题库列表的一本书（编辑 / 练习册风纸张卡片）：
 * 圆角 16 + 1px divider 描边，主行与元信息行之间用细线分隔，
 * 学科标签走 brandSoft + brand，删除降级为描边次级动作。
 */
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
          Column({ space: 6 }) {
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
            .fontSize(24)
            .fontColor(this.colors().brand)
        }
        .width('100%')
        .padding({ left: 18, right: 16, top: 16, bottom: 14 })
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

      Divider()
        .strokeWidth(HAIRLINE)
        .color(this.colors().divider)

      Row({ space: 10 }) {
        Text(this.subject)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().brand)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.colors().brandSoft)
          .borderRadius(BADGE_RADIUS)

        Text(this.createDate)
          .fontSize(12)
          .fontColor(this.colors().textCaption)

        Blank()

        Button() {
          Text('删除')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().error)
        }
        .type(ButtonType.Normal)
        .height(32)
        .padding({ left: 14, right: 14 })
        .backgroundColor(this.colors().cardBackground)
        .border({ width: HAIRLINE, color: this.colors().divider })
        .borderRadius(BADGE_RADIUS)
        .enabled(!this.deleting)
        .accessibilityText('删除题库：' + this.bankName)
        .onClick(() => {
          this.onDelete()
        })
      }
      .width('100%')
      .height(52)
      .padding({ left: 18, right: 12 })
    }
    .width('100%')
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(SHEET_RADIUS)
    .border({ width: HAIRLINE, color: this.colors().divider })
    .clip(true)
  }
}
