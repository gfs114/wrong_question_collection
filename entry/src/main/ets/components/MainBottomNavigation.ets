import {
  themePalette
} from '../constants/AppTheme'
import { ImmersiveMaterials } from '../constants/ImmersiveMaterials'
import { AppColors } from '../theme/AppColors'
import { MainTabIndex } from '../models/MainTab'
import { SafeAreaInsets, SafeAreaUtils } from '../utils/SafeAreaUtils'

@Component
export struct MainBottomNavigation {
  @Prop selectedIndex: number = MainTabIndex.HOME
  @StorageProp('safeAreaInsets') safeAreaInsets: SafeAreaInsets = {
    top: 0, left: 0, right: 0, bottom: 0
  }
  @StorageProp('darkMode') darkMode: boolean = false
  onSelect: (index: number) => void = () => {
  }

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  @Builder
  private NavigationItem(label: string, symbol: Resource, index: number) {
    Button() {
      Column({ space: 4 }) {
        SymbolGlyph(symbol)
          .fontSize(25)
          .fontWeight(this.selectedIndex === index ? FontWeight.Bold : FontWeight.Medium)
          .fontColor([this.selectedIndex === index ? this.colors().brand : this.colors().navInactive])

        Text(label)
          .fontSize(12)
          .fontWeight(this.selectedIndex === index ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.selectedIndex === index ? this.colors().brand : this.colors().navInactive)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .scale({
        x: this.selectedIndex === index ? 1.05 : 1,
        y: this.selectedIndex === index ? 1.05 : 1
      })
      .animation({ duration: 160, curve: Curve.EaseOut })
    }
    .type(ButtonType.Normal)
    .layoutWeight(1)
    .height('100%')
    .padding(0)
    .backgroundColor(Color.Transparent)
    .borderRadius(24)
    .accessibilityText(label)
    .onClick(() => {
      if (this.selectedIndex !== index) {
        this.onSelect(index)
      }
    })
  }

  build() {
    Row({ space: 2 }) {
      this.NavigationItem('首页', $r('sys.symbol.house_fill'), MainTabIndex.HOME)
      this.NavigationItem('书籍', $r('sys.symbol.book'), MainTabIndex.BOOKS)
      this.NavigationItem('错题', $r('sys.symbol.exclamationmark_circle_fill'), MainTabIndex.WRONG_QUESTIONS)
      this.NavigationItem('我的', $r('sys.symbol.person_fill'), MainTabIndex.MINE)
    }
    .width('92%')
    .height(76)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .margin({ bottom: 12 + SafeAreaUtils.bottom(this.safeAreaInsets) })
    .borderRadius(38)
    .systemMaterial(ImmersiveMaterials.navigationFor(this.darkMode))
  }
}
