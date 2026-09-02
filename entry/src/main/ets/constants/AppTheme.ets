import { AppColors } from '../theme/AppColors'
import { DarkColors } from '../theme/DarkColors'
import { LightColors } from '../theme/LightColors'

export const PAGE_PADDING: number = 20
export const CARD_RADIUS: number = 20
export const CARD_GAP: number = 12
export const CONTENT_MAX_WIDTH: number = 760
export const TITLE_FONT_SIZE: number = 24
export const SUBTITLE_FONT_SIZE: number = 16
export const BODY_FONT_SIZE: number = 14

export function themePalette(dark: boolean): AppColors {
  return dark ? DarkColors.INSTANCE : LightColors.INSTANCE
}
