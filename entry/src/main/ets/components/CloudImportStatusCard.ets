import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  SUBTITLE_FONT_SIZE,
  themePalette
} from '../constants/AppTheme'
import { AppColors } from '../theme/AppColors'

@Component
export struct CloudImportStatusCard {
  @Prop status: string = '上传中'
  @Prop progressCurrent: number = 0
  @Prop progressTotal: number = 0
  @Prop errorMessage: string = ''
  @Prop retryHint: string = '网络异常时可重试'
  @Prop serverStatus: string = '服务器识别中'
  @StorageProp('darkMode') darkMode: boolean = false

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  private safeProgressTotal(): number {
    if (!Number.isFinite(this.progressTotal) || this.progressTotal <= 0) {
      return 1
    }
    return this.progressTotal
  }

  private safeProgressCurrent(): number {
    if (!Number.isFinite(this.progressCurrent) || this.progressCurrent <= 0) {
      return 0
    }
    return Math.min(this.progressCurrent, this.safeProgressTotal())
  }

  build() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Text('云')
          .width(42)
          .height(42)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.colors().brand)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.colors().pageBackground)
          .borderRadius(21)

        Column({ space: 3 }) {
          Text('当前状态')
            .fontSize(12)
            .fontColor(this.colors().textCaption)

          Text(this.status)
            .fontSize(SUBTITLE_FONT_SIZE)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.errorMessage.length > 0 ? this.colors().error : this.colors().textPrimary)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Column({ space: 8 }) {
        Row() {
          Text('处理进度')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().textCaption)

          Blank()

          Text(this.progressCurrent.toString() + ' / ' + this.progressTotal.toString())
            .fontSize(BODY_FONT_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().textPrimary)
        }
        .width('100%')

        Progress({
          value: this.safeProgressCurrent(),
          total: this.safeProgressTotal(),
          type: ProgressType.Linear
        })
          .width('100%')
          .height(8)
          .color(this.colors().brand)
          .backgroundColor(this.colors().pageBackground)
      }
      .width('100%')

      Row() {
        Text('服务端识别状态')
          .fontSize(BODY_FONT_SIZE)
          .fontColor(this.colors().textCaption)

        Blank()

        Text(this.serverStatus)
          .fontSize(BODY_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
      }
      .width('100%')

      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .width('100%')
          .padding(12)
          .fontSize(BODY_FONT_SIZE)
          .fontColor(this.colors().error)
          .lineHeight(21)
          .backgroundColor(this.colors().errorSoft)
          .borderRadius(12)
      }

      if (this.retryHint.length > 0) {
        Text('重试提示：' + this.retryHint)
          .width('100%')
          .fontSize(12)
          .fontColor(this.colors().textCaption)
          .lineHeight(19)
      }
    }
    .width('100%')
    .padding(20)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(CARD_RADIUS)
  }
}
