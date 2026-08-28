import {
  COLOR_TEXT_CAPTION,
  COLOR_TEXT_PRIMARY,
  SUBTITLE_FONT_SIZE
} from '../constants/AppTheme'

@Component
export struct SectionTitle {
  @Prop title: string = ''
  @Prop detail: string = ''
  @Prop showDetail: boolean = false

  build() {
    Row() {
      Text(this.title)
        .fontSize(SUBTITLE_FONT_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_TEXT_PRIMARY)

      Blank()

      if (this.showDetail) {
        Text(this.detail)
          .fontSize(13)
          .fontColor(COLOR_TEXT_CAPTION)
      }
    }
    .width('100%')
    .height(36)
  }
}
