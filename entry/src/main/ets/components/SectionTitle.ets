import {
  HAIRLINE,
  SECTION_DETAIL_SIZE,
  SECTION_TITLE_SIZE
} from '../constants/EditorialStyle'
import { themePalette } from '../constants/AppTheme'
import { AppColors } from '../theme/AppColors'

/**
 * 章节标题（编辑 / 练习册风）：13px Bold + letterSpacing(1)，右侧可选说明，
 * 下方收一条细线，与首页 HomeRecentSection 的章节标题同一套排版。
 */
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
    Column({ space: 10 }) {
      Row() {
        Text(this.title)
          .fontSize(SECTION_TITLE_SIZE)
          .fontWeight(FontWeight.Bold)
          .letterSpacing(1)
          .fontColor(this.colors().textPrimary)

        Blank()

        if (this.showDetail) {
          Text(this.detail)
            .fontSize(SECTION_DETAIL_SIZE)
            .fontColor(this.colors().textCaption)
        }
      }
      .width('100%')

      Divider()
        .strokeWidth(HAIRLINE)
        .color(this.colors().divider)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
