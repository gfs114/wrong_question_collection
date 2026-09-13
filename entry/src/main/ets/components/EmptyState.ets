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

/**
 * 空态（编辑 / 练习册风）：方形书签章 + 标题 + 说明，动作降级为描边次级按钮，
 * 与首页「导入资料」的次级操作同一套语言。
 */
@Component
export struct EmptyState {
  @Prop glyph: string = '·'
  @Prop title: string = ''
  @Prop description: string = ''
  @Prop actionLabel: string = ''
  @Prop showAction: boolean = false
  @Prop fillAvailable: boolean = true
  @StorageProp('darkMode') darkMode: boolean = false
  onAction: () => void = () => {
  }

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  private emptyStateMinHeight(): Length {
    return this.fillAvailable ? '100%' : 180
  }

  build() {
    Column({ space: 10 }) {
      Text(this.glyph)
        .width(64)
        .height(64)
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.colors().brand)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.colors().brandSoft)
        .borderRadius(SHEET_RADIUS)

      Text(this.title)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .letterSpacing(1)
        .fontColor(this.colors().textPrimary)
        .textAlign(TextAlign.Center)

      Text(this.description)
        .fontSize(BODY_FONT_SIZE)
        .fontColor(this.colors().textCaption)
        .textAlign(TextAlign.Center)
        .lineHeight(22)

      if (this.showAction) {
        Button() {
          Text(this.actionLabel)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().brand)
        }
        .type(ButtonType.Normal)
        .height(48)
        .padding({ left: 24, right: 24 })
        .margin({ top: 10 })
        .backgroundColor(this.colors().cardBackground)
        .border({ width: HAIRLINE, color: this.colors().brand })
        .borderRadius(BADGE_RADIUS + 6)
        .onClick(() => {
          this.onAction()
        })
      }
    }
    .width('100%')
    .constraintSize({ minHeight: this.emptyStateMinHeight() })
    .padding({ left: 32, right: 32, top: 24, bottom: 24 })
    .justifyContent(FlexAlign.Center)
  }
}
