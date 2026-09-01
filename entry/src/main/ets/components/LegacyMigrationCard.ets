import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  COLOR_CARD_BG,
  COLOR_DANGER,
  COLOR_PAGE_BG,
  COLOR_PRIMARY,
  COLOR_SUCCESS_TEXT,
  COLOR_TEXT_CAPTION,
  COLOR_TEXT_PRIMARY
} from '../constants/AppTheme'
import {
  LegacyMigrationStage,
  LegacyMigrationState
} from '../models/LegacyMigrationModels'

@Component
export struct LegacyMigrationCard {
  @Prop state: LegacyMigrationState = new LegacyMigrationState(
    '', LegacyMigrationStage.UNCLAIMED, new Array<string>(), '', new Array<string>(),
    new Array<string>(), new Array<string>(), 0, 0, 0, '', '', 0)
  @Prop signedIn: boolean = false
  @Prop busy: boolean = false
  onStart: () => void = () => {
  }
  onRetry: () => void = () => {
  }

  private stageLabel(): string {
    if (this.state.stage === LegacyMigrationStage.UNCLAIMED) {
      return '未迁移'
    }
    if (this.state.stage === LegacyMigrationStage.UPLOADING) {
      return '迁移中'
    }
    if (this.state.stage === LegacyMigrationStage.VERIFYING) {
      return '正在校验'
    }
    if (this.state.stage === LegacyMigrationStage.COMPLETED) {
      return '迁移完成'
    }
    return '迁移失败'
  }

  private stageColor(): string {
    if (this.state.stage === LegacyMigrationStage.COMPLETED) {
      return COLOR_SUCCESS_TEXT
    }
    if (this.state.stage === LegacyMigrationStage.FAILED) {
      return COLOR_DANGER
    }
    return COLOR_PRIMARY
  }

  private progressText(): string {
    if (this.state.stage === LegacyMigrationStage.UPLOADING) {
      return '已上传 ' + this.state.acknowledgedBankIds.length.toString() + '/' +
        this.state.totalBanks.toString() + ' 个题库'
    }
    if (this.state.stage === LegacyMigrationStage.VERIFYING) {
      return '已校验 ' + this.state.verifiedBankIds.length.toString() + '/' +
        this.state.totalBanks.toString() + ' 个题库'
    }
    return ''
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Text('迁')
          .width(36)
          .height(36)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_PRIMARY)
          .textAlign(TextAlign.Center)
          .backgroundColor(COLOR_PAGE_BG)
          .borderRadius(18)

        Column({ space: 2 }) {
          Text('旧数据迁移')
            .fontSize(BODY_FONT_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_TEXT_PRIMARY)

          Text(this.stageLabel())
            .fontSize(13)
            .fontColor(this.stageColor())
        }
        .alignItems(HorizontalAlign.Start)

        Blank()
      }
      .width('100%')

      Text(this.state.totalBanks.toString() + ' 个题库 · ' +
        this.state.totalQuestions.toString() + ' 道题目 · ' +
        this.state.totalImages.toString() + ' 张本机题图')
        .width('100%')
        .fontSize(13)
        .fontColor(COLOR_TEXT_CAPTION)

      Text('迁移会把本机文字数据绑定到当前登录的华为账号，本机数据不会被删除。')
        .width('100%')
        .fontSize(13)
        .fontColor(COLOR_TEXT_CAPTION)

      if (!this.signedIn) {
        Text('登录后才能开始迁移')
          .width('100%')
          .fontSize(13)
          .fontColor(COLOR_TEXT_CAPTION)
      }

      if (this.state.stage === LegacyMigrationStage.UNCLAIMED) {
        Button(this.busy ? '正在准备…' : '开始迁移')
          .type(ButtonType.Normal)
          .width('100%')
          .height(44)
          .fontSize(BODY_FONT_SIZE)
          .fontColor('#FFFFFF')
          .backgroundColor(this.signedIn && !this.busy ? COLOR_PRIMARY : '#8E99AA')
          .borderRadius(12)
          .enabled(this.signedIn && !this.busy)
          .onClick(() => {
            this.onStart()
          })
      } else if (this.state.stage === LegacyMigrationStage.UPLOADING ||
        this.state.stage === LegacyMigrationStage.VERIFYING) {
        Row({ space: 10 }) {
          LoadingProgress()
            .width(20)
            .height(20)
            .color(COLOR_PRIMARY)

          Text(this.progressText())
            .fontSize(13)
            .fontColor(COLOR_TEXT_CAPTION)

          Blank()
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
      } else if (this.state.stage === LegacyMigrationStage.FAILED) {
        if (this.state.errorMessage.length > 0) {
          Text(this.state.errorMessage)
            .width('100%')
            .fontSize(13)
            .fontColor(COLOR_DANGER)
        }

        Button(this.busy ? '正在重试…' : '重试')
          .type(ButtonType.Normal)
          .width('100%')
          .height(44)
          .fontSize(BODY_FONT_SIZE)
          .fontColor('#FFFFFF')
          .backgroundColor(this.signedIn && !this.busy ? COLOR_PRIMARY : '#8E99AA')
          .borderRadius(12)
          .enabled(this.signedIn && !this.busy)
          .onClick(() => {
            this.onRetry()
          })
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(COLOR_CARD_BG)
    .borderRadius(CARD_RADIUS)
  }
}
