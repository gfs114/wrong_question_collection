import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  COLOR_CARD_BG,
  COLOR_DANGER,
  COLOR_PAGE_BG,
  COLOR_PRIMARY,
  COLOR_TEXT_CAPTION,
  COLOR_TEXT_PRIMARY,
  SUBTITLE_FONT_SIZE
} from '../constants/AppTheme'

@Component
export struct CloudImportStatusCard {
  @Prop status: string = '上传中'
  @Prop progressCurrent: number = 0
  @Prop progressTotal: number = 0
  @Prop errorMessage: string = ''
  @Prop retryHint: string = '网络异常时可重试'
  @Prop serverStatus: string = '服务器识别中'

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
          .fontColor(COLOR_PRIMARY)
          .textAlign(TextAlign.Center)
          .backgroundColor(COLOR_PAGE_BG)
          .borderRadius(21)

        Column({ space: 3 }) {
          Text('当前状态')
            .fontSize(12)
            .fontColor(COLOR_TEXT_CAPTION)

          Text(this.status)
            .fontSize(SUBTITLE_FONT_SIZE)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.errorMessage.length > 0 ? COLOR_DANGER : COLOR_TEXT_PRIMARY)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Column({ space: 8 }) {
        Row() {
          Text('处理进度')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(COLOR_TEXT_CAPTION)

          Blank()

          Text(this.progressCurrent.toString() + ' / ' + this.progressTotal.toString())
            .fontSize(BODY_FONT_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_TEXT_PRIMARY)
        }
        .width('100%')

        Progress({
          value: this.safeProgressCurrent(),
          total: this.safeProgressTotal(),
          type: ProgressType.Linear
        })
          .width('100%')
          .height(8)
          .color(COLOR_PRIMARY)
          .backgroundColor(COLOR_PAGE_BG)
      }
      .width('100%')

      Row() {
        Text('服务端识别状态')
          .fontSize(BODY_FONT_SIZE)
          .fontColor(COLOR_TEXT_CAPTION)

        Blank()

        Text(this.serverStatus)
          .fontSize(BODY_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_TEXT_PRIMARY)
      }
      .width('100%')

      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .width('100%')
          .padding(12)
          .fontSize(BODY_FONT_SIZE)
          .fontColor(COLOR_DANGER)
          .lineHeight(21)
          .backgroundColor('#FFF2F2')
          .borderRadius(12)
      }

      if (this.retryHint.length > 0) {
        Text('重试提示：' + this.retryHint)
          .width('100%')
          .fontSize(12)
          .fontColor(COLOR_TEXT_CAPTION)
          .lineHeight(19)
      }
    }
    .width('100%')
    .padding(20)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(COLOR_CARD_BG)
    .borderRadius(CARD_RADIUS)
  }
}
