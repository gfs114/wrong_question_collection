import {
  BADGE_RADIUS,
  HAIRLINE,
  SHEET_RADIUS
} from '../constants/EditorialStyle'
import {
  BODY_FONT_SIZE,
  themePalette
} from '../constants/AppTheme'
import { AppColors } from '../theme/AppColors'
import { MathContentUtils } from '../utils/MathContentUtils'

/**
 * 错题列表的一条（编辑 / 练习册风纸张卡片）：
 * 圆角 16 + 1px divider 描边，学科走 brandSoft，掌握状态做成行内小标签，
 * 题干用原生轻量预览（不使用 Web / 详情渲染器）。
 */
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
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text(this.subject)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().brand)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor(this.colors().brandSoft)
            .borderRadius(BADGE_RADIUS)

          Text(this.mastered ? '已掌握' : '待复习')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.mastered ? this.colors().successText : this.colors().textCaption)

          Blank()
        }
        .width('100%')

        Text(MathContentUtils.toPlainPreview(this.questionText))
          .width('100%')
          .fontSize(BODY_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
          .maxLines(3)

        Divider()
          .strokeWidth(HAIRLINE)
          .color(this.colors().divider)

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
    .borderRadius(SHEET_RADIUS)
    .border({ width: HAIRLINE, color: this.colors().divider })
    .onClick(() => {
      this.onOpen()
    })
  }
}
