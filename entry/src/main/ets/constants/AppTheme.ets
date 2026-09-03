import { AppColors } from '../theme/AppColors'
import { DarkColors } from '../theme/DarkColors'
import { LightColors } from '../theme/LightColors'

export const PAGE_PADDING: number = 20
export const CARD_RADIUS: number = 20
export const CARD_GAP: number = 12
export const CONTENT_MAX_WIDTH: number = 760
export const SUBTITLE_FONT_SIZE: number = 16
export const BODY_FONT_SIZE: number = 14

// 原生 Tabs 悬浮 TabBar 开启 barOverlap 后，内容区会延伸到悬浮栏下方，
// 滚动内容需要预留这段底部距离；TabBar 自身的安全区由系统处理。
// 悬浮栏还带 barBottomMargin(23vp)，因此预留 = 底边距 + TabBar 高度 + 呼吸间距，
// 保证最后一项内容可以完整滚到 TabBar 上方。
export const TAB_BAR_CLEARANCE: number = 96

export function themePalette(dark: boolean): AppColors {
  return dark ? DarkColors.INSTANCE : LightColors.INSTANCE
}
