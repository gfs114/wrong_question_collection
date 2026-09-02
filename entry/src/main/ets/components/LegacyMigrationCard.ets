import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  themePalette
} from '../constants/AppTheme'
import { AppColors } from '../theme/AppColors'
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
  @StorageProp('darkMode') darkMode: boolean = false
  onStart: () => void = () => {
  }
  onRetry: () => void = () => {
  }

  private colors(): AppColors {
    return themePalette(this.darkMode)
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
      return this.colors().successText
    }
    if (this.state.stage === LegacyMigrationStage.FAILED) {
      return this.colors().error
    }
    return this.colors().brand
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
          .fontColor(this.colors().brand)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.colors().pageBackground)
          .borderRadius(18)

        Column({ space: 2 }) {
          Text('旧数据迁移')
            .fontSize(BODY_FONT_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().textPrimary)

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
        .fontColor(this.colors().textCaption)

      Text('迁移会把本机文字数据绑定到当前登录的华为账号，本机数据不会被删除。')
        .width('100%')
        .fontSize(13)
        .fontColor(this.colors().textCaption)

      if (!this.signedIn) {
        Text('登录后才能开始迁移')
          .width('100%')
          .fontSize(13)
          .fontColor(this.colors().textCaption)
      }

      if (this.state.stage === LegacyMigrationStage.UNCLAIMED) {
        Button(this.busy ? '正在准备…' : '开始迁移')
          .type(ButtonType.Normal)
          .width('100%')
          .height(44)
          .fontSize(BODY_FONT_SIZE)
          .fontColor(this.colors().onBrand)
          .backgroundColor(this.signedIn && !this.busy ? this.colors().brand : this.colors().disabled)
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
            .color(this.colors().brand)

          Text(this.progressText())
            .fontSize(13)
            .fontColor(this.colors().textCaption)

          Blank()
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
      } else if (this.state.stage === LegacyMigrationStage.FAILED) {
        if (this.state.errorMessage.length > 0) {
          Text(this.state.errorMessage)
            .width('100%')
            .fontSize(13)
            .fontColor(this.colors().error)
        }

        Button(this.busy ? '正在重试…' : '重试')
          .type(ButtonType.Normal)
          .width('100%')
          .height(44)
          .fontSize(BODY_FONT_SIZE)
          .fontColor(this.colors().onBrand)
          .backgroundColor(this.signedIn && !this.busy ? this.colors().brand : this.colors().disabled)
          .borderRadius(12)
          .enabled(this.signedIn && !this.busy)
          .onClick(() => {
            this.onRetry()
          })
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(CARD_RADIUS)
  }
}
