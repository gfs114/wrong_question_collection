import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  themePalette
} from '../constants/AppTheme'
import { AppColors } from '../theme/AppColors'
import { SectionTitle } from './SectionTitle'

@Component
export struct HomeRecentSection {
  @Prop title: string = ''
  @Prop emptyText: string = ''
  @Prop items: Array<string> = new Array<string>()
  @StorageProp('darkMode') darkMode: boolean = false
  onOpen: (index: number) => void = () => {
  }

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  build() {
    Column({ space: 8 }) {
      SectionTitle({
        title: this.title,
        detail: this.items.length > 0 ? '查看全部' : '',
        showDetail: this.items.length > 0
      })

      if (this.items.length === 0) {
        Row({ space: 10 }) {
          Text('·')
            .width(30)
            .height(30)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors().brand)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.colors().brandSoft)
            .borderRadius(15)

          Text(this.emptyText)
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().textCaption)
        }
        .width('100%')
        .height(62)
        .padding({ left: 16, right: 16 })
        .backgroundColor(this.colors().cardBackground)
        .borderRadius(CARD_RADIUS)
      } else {
        Column() {
          ForEach(this.items, (item: string, index: number) => {
            Row({ space: 12 }) {
              Text((index + 1).toString())
                .width(30)
                .height(30)
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.colors().brand)
                .textAlign(TextAlign.Center)
                .backgroundColor(this.colors().brandSoft)
                .borderRadius(15)

              Text(item)
                .layoutWeight(1)
                .fontSize(BODY_FONT_SIZE)
                .fontColor(this.colors().textPrimary)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })

              Text('›')
                .fontSize(24)
                .fontColor(this.colors().textCaption)
            }
            .width('100%')
            .height(58)
            .padding({ left: 16, right: 14, top: 10, bottom: 10 })
            .onClick(() => {
              this.onOpen(index)
            })

            if (index < this.items.length - 1) {
              Divider()
                .margin({ left: 58 })
                .color(this.colors().divider)
            }
          }, (item: string, index: number): string => index.toString() + item)
        }
        .width('100%')
        .backgroundColor(this.colors().cardBackground)
        .borderRadius(CARD_RADIUS)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
