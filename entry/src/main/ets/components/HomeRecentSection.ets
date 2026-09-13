import {
  BODY_FONT_SIZE,
  themePalette
} from '../constants/AppTheme'
import {
  BADGE_RADIUS,
  BADGE_SIZE,
  HAIRLINE,
  SECTION_TITLE_SIZE,
  SHEET_RADIUS
} from '../constants/EditorialStyle'
import { AppColors } from '../theme/AppColors'

@Component
export struct HomeRecentSection {
  @Prop title: string = ''
  @Prop emptyText: string = ''
  @Prop items: Array<string> = new Array<string>()
  @Prop actionLabel: string = '查看列表'
  @StorageProp('darkMode') darkMode: boolean = false
  onViewAll: () => void = () => {
  }

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  // 章节标题提供唯一的列表级跳转；摘要行本身只展示内容，避免造成可直达详情的误解。
  @Builder
  private SectionHead() {
    Column({ space: 10 }) {
      Row() {
        Text(this.title)
          .fontSize(SECTION_TITLE_SIZE)
          .fontWeight(FontWeight.Bold)
          .letterSpacing(1)
          .fontColor(this.colors().textPrimary)

        Blank()

        if (this.items.length > 0) {
          Button(this.actionLabel)
            .type(ButtonType.Normal)
            .height(48)
            .padding({ left: 12, right: 12 })
            .fontSize(12)
            .fontColor(this.colors().brand)
            .backgroundColor(Color.Transparent)
            .accessibilityText(this.actionLabel)
            .onClick(() => {
              this.onViewAll()
            })
        }
      }
      .width('100%')

      Divider()
        .strokeWidth(HAIRLINE)
        .color(this.colors().divider)
    }
    .width('100%')
  }

  build() {
    Column({ space: 10 }) {
      this.SectionHead()

      if (this.items.length === 0) {
        Row({ space: 10 }) {
          Text('·')
            .width(28)
            .height(28)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors().brand)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.colors().brandSoft)
            .borderRadius(BADGE_RADIUS)

          Text(this.emptyText)
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().textCaption)
        }
        .width('100%')
        .height(60)
        .padding({ left: 16, right: 16 })
        .backgroundColor(this.colors().cardBackground)
        .borderRadius(SHEET_RADIUS)
        .border({ width: HAIRLINE, color: this.colors().divider })
      } else {
        Column() {
          ForEach(this.items, (item: string, index: number) => {
            Row({ space: 12 }) {
              // 序号做成方形书签，而不是圆点，贴近练习册的编号观感。
              Text((index + 1).toString())
                .width(BADGE_SIZE)
                .height(BADGE_SIZE)
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.colors().brand)
                .textAlign(TextAlign.Center)
                .backgroundColor(this.colors().brandSoft)
                .borderRadius(BADGE_RADIUS)

              Text(item)
                .layoutWeight(1)
                .fontSize(BODY_FONT_SIZE)
                .fontColor(this.colors().textPrimary)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })

            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .accessibilityText('摘要：' + item)

            if (index < this.items.length - 1) {
              Divider()
                .strokeWidth(HAIRLINE)
                .margin({ left: 56 })
                .color(this.colors().divider)
            }
          }, (item: string, index: number): string => index.toString() + item)
        }
        .width('100%')
        .backgroundColor(this.colors().cardBackground)
        .borderRadius(SHEET_RADIUS)
        .border({ width: HAIRLINE, color: this.colors().divider })
        .clip(true)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
