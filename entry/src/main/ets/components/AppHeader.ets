import {
  PAGE_PADDING,
  TITLE_FONT_SIZE,
  themePalette
} from '../constants/AppTheme'
import { ImmersiveMaterials } from '../constants/ImmersiveMaterials'
import { AppColors } from '../theme/AppColors'
import { SafeAreaInsets, SafeAreaUtils } from '../utils/SafeAreaUtils'

@Component
export struct AppHeader {
  @Prop title: string = ''
  @Prop actionLabel: string = ''
  @Prop showAction: boolean = false
  @Prop showBack: boolean = false
  @StorageProp('safeAreaInsets') safeAreaInsets: SafeAreaInsets = {
    top: 0, left: 0, right: 0, bottom: 0
  }
  @StorageProp('darkMode') darkMode: boolean = false
  onAction: () => void = () => {
  }
  onBack: () => void = () => {
  }

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  build() {
    Row() {
      if (this.showBack) {
        Button() {
          Text('‹')
            .fontSize(30)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().textPrimary)
        }
        .type(ButtonType.Normal)
        .width(48)
        .height(48)
        .padding(0)
        .margin({ right: 8 })
        .borderRadius(24)
        .systemMaterial(ImmersiveMaterials.floatingButtonFor(this.darkMode))
        .accessibilityText('返回')
        .onClick(() => {
          this.onBack()
        })
      }

      Text(this.title)
        .fontSize(TITLE_FONT_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.colors().textPrimary)
        .maxLines(1)

      Blank()

      if (this.showAction) {
        Button() {
          Text(this.actionLabel)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().onBrand)
        }
        .type(ButtonType.Normal)
        .height(48)
        .padding({ left: 16, right: 16 })
        .backgroundColor(this.colors().brand)
        .borderRadius(14)
        .onClick(() => {
          this.onAction()
        })
      }
    }
    .width('100%')
    .height(76)
    .padding({
      left: PAGE_PADDING,
      right: PAGE_PADDING,
      top: SafeAreaUtils.top(this.safeAreaInsets)
    })
    .systemMaterial(ImmersiveMaterials.headerFor(this.darkMode))
  }
}
