import { themePalette } from '../constants/AppTheme'
import { HAIRLINE, SHEET_RADIUS } from '../constants/EditorialStyle'
import { AppColors } from '../theme/AppColors'

@Component
export struct HomeOverviewCard {
  @Prop pendingCount: number = 0
  @Prop wrongCount: number = 0
  @Prop masteredCount: number = 0
  @Prop masteryRate: number = 0
  @Prop reviewLabel: string = '今日待复习'
  @Prop wrongLabel: string = '错题总数'
  @Prop masteredLabel: string = '已掌握'
  @Prop masteryLabel: string = '掌握率'
  @Prop reviewActionLabel: string = '开始复习'
  @StorageProp('darkMode') darkMode: boolean = false
  onStartReview: () => void = () => {
  }

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  private clampRate(): number {
    if (this.masteryRate < 0) {
      return 0
    }
    return this.masteryRate > 100 ? 100 : this.masteryRate
  }

  // 小号间距字 + 细线，练习册的章节标题感。
  @Builder
  private StatItem(label: string, value: string, showRule: boolean) {
    Row() {
      if (showRule) {
        Column()
          .width(HAIRLINE)
          .height(30)
          .backgroundColor(this.colors().divider)
          .margin({ right: 14 })
      }

      Column({ space: 4 }) {
        Text(value)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.colors().textPrimary)

        Text(label)
          .fontSize(12)
          .fontColor(this.colors().textCaption)
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column() {
      // 主数字区：待复习数量是最重要的信息，给它最大字号与唯一的强调色。
      Row() {
        Column({ space: 2 }) {
          Text(this.reviewLabel)
            .fontSize(12)
            .letterSpacing(1)
            .fontColor(this.colors().textCaption)

          Row({ space: 4 }) {
            Text(this.pendingCount.toString())
              .fontSize(54)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.pendingCount > 0 ? this.colors().error : this.colors().successText)

            Text('题')
              .fontSize(14)
              .fontColor(this.colors().textCaption)
              .margin({ bottom: 8 })
          }
          .alignItems(VerticalAlign.Bottom)

          Text(this.pendingCount > 0 ? '今天再巩固一遍，记得会更牢' : '今天的复习任务已经完成')
            .fontSize(13)
            .fontColor(this.colors().textCaption)
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button() {
          Text(this.reviewActionLabel)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pendingCount > 0 ? this.colors().onBrand : this.colors().textCaption)
        }
        .type(ButtonType.Normal)
        .height(48)
        .padding({ left: 20, right: 20 })
        .backgroundColor(this.pendingCount > 0 ? this.colors().brand : this.colors().chipBackground)
        .borderRadius(23)
        .enabled(this.pendingCount > 0)
        .onClick(() => {
          this.onStartReview()
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 掌握进度：细轨道 + 品牌色填充，数字只在这里出现一次。
      Column({ space: 8 }) {
        Row() {
          Text('掌握进度')
            .fontSize(12)
            .fontColor(this.colors().textCaption)

          Blank()

          Text(this.clampRate().toString() + '%')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().brand)
        }
        .width('100%')

        Stack({ alignContent: Alignment.Start }) {
          Column()
            .width('100%')
            .height(6)
            .backgroundColor(this.colors().divider)
            .borderRadius(3)

          Column()
            .width(this.clampRate().toString() + '%')
            .height(6)
            .backgroundColor(this.colors().brand)
            .borderRadius(3)
        }
        .width('100%')
        .height(6)
      }
      .width('100%')
      .margin({ top: 18 })

      Divider()
        .strokeWidth(HAIRLINE)
        .color(this.colors().divider)
        .margin({ top: 18, bottom: 16 })

      Row() {
        this.StatItem(this.wrongLabel, this.wrongCount.toString(), false)
        this.StatItem(this.masteredLabel, this.masteredCount.toString(), true)
        this.StatItem(this.masteryLabel, this.clampRate().toString() + '%', true)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 22, right: 22, top: 20, bottom: 18 })
    .borderRadius(SHEET_RADIUS)
    .backgroundColor(this.colors().cardBackground)
    .border({ width: HAIRLINE, color: this.colors().divider })
  }
}
