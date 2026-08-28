import {
  COLOR_NAV_INACTIVE,
  COLOR_PRIMARY
} from '../constants/AppTheme'
import { ImmersiveMaterials } from '../constants/ImmersiveMaterials'
import { MainTabIndex } from '../models/MainTab'

@Component
export struct MainBottomNavigation {
  @Prop selectedIndex: number = MainTabIndex.HOME
  onSelect: (index: number) => void = () => {
  }

  @Builder
  private NavigationItem(label: string, symbol: Resource, index: number) {
    Button() {
      Column({ space: 4 }) {
        SymbolGlyph(symbol)
          .fontSize(25)
          .fontWeight(this.selectedIndex === index ? FontWeight.Bold : FontWeight.Medium)
          .fontColor([this.selectedIndex === index ? COLOR_PRIMARY : COLOR_NAV_INACTIVE])

        Text(label)
          .fontSize(12)
          .fontWeight(this.selectedIndex === index ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.selectedIndex === index ? COLOR_PRIMARY : COLOR_NAV_INACTIVE)
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
    .height(60)
    .padding(0)
    .backgroundColor('#00000000')
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
    .margin({ bottom: 12 })
    .borderRadius(38)
    .systemMaterial(ImmersiveMaterials.navigation)
  }
}
