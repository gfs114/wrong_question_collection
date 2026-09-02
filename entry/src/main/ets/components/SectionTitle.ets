import {
  SUBTITLE_FONT_SIZE,
  themePalette
} from '../constants/AppTheme'
import { AppColors } from '../theme/AppColors'

@Component
export struct SectionTitle {
  @Prop title: string = ''
  @Prop detail: string = ''
  @Prop showDetail: boolean = false
  @StorageProp('darkMode') darkMode: boolean = false

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  build() {
    Row() {
      Text(this.title)
        .fontSize(SUBTITLE_FONT_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.colors().textPrimary)

      Blank()

      if (this.showDetail) {
        Text(this.detail)
          .fontSize(13)
          .fontColor(this.colors().textCaption)
      }
    }
    .width('100%')
    .height(36)
  }
}
