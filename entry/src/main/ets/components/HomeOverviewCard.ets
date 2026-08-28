import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  COLOR_DANGER,
  COLOR_PRIMARY,
  COLOR_TEXT_CAPTION,
  COLOR_TEXT_PRIMARY,
  SUBTITLE_FONT_SIZE
} from '../constants/AppTheme'
import { ImmersiveMaterials } from '../constants/ImmersiveMaterials'

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
  onStartReview: () => void = () => {
  }

  @Builder
  private StatItem(label: string, value: string) {
    Column({ space: 6 }) {
      Text(value)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_TEXT_PRIMARY)

      Text(label)
        .fontSize(12)
        .fontColor(COLOR_TEXT_CAPTION)
        .maxLines(1)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: 20 }) {
      Row() {
        Column({ space: 6 }) {
          Text(this.reviewLabel)
            .fontSize(BODY_FONT_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_TEXT_CAPTION)

          Text(this.pendingCount.toString())
            .fontSize(42)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLOR_DANGER)

          Text(this.pendingCount > 0 ? '今天再巩固一遍，记得会更牢' : '今天的复习任务已经完成')
            .fontSize(13)
            .fontColor(COLOR_TEXT_CAPTION)
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button() {
          Text(this.reviewActionLabel)
            .fontSize(SUBTITLE_FONT_SIZE)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
        }
        .type(ButtonType.Normal)
        .height(50)
        .padding({ left: 20, right: 20 })
        .backgroundColor(COLOR_PRIMARY)
        .borderRadius(25)
        .enabled(this.pendingCount > 0)
        .opacity(this.pendingCount > 0 ? 1 : 0.55)
        .onClick(() => {
          this.onStartReview()
        })
      }
      .width('100%')

      Divider()
        .color('#1A536077')

      Row({ space: 12 }) {
        this.StatItem(this.wrongLabel, this.wrongCount.toString())
        this.StatItem(this.masteredLabel, this.masteredCount.toString())
        this.StatItem(this.masteryLabel, this.masteryRate.toString() + '%')
      }
      .width('100%')
    }
    .width('100%')
    .padding(22)
    .borderRadius(CARD_RADIUS + 6)
    .systemMaterial(ImmersiveMaterials.overviewCard)
  }
}
