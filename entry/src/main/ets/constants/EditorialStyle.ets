/**
 * 编辑 / 练习册风（方向 A）的共享设计令牌。
 * 首页重构时建立的版式语言：纸张卡片 = 圆角 16 + 1px divider 描边，
 * 章节标题 = 13px Bold + letterSpacing(1) + 细线，统计 = 竖细线分隔，
 * 徽标 = 方形书签（28×28 / 圆角 8 / brandSoft 底 + brand 字）。
 * 各页面与组件统一引用这里，避免同一套比例在多处各写一遍。
 */

/** 纸张卡片圆角。 */
export const SHEET_RADIUS: number = 16

/** 细线宽度：所有分隔线、描边统一 1px。 */
export const HAIRLINE: number = 1

/** 栏（章节）之间的间距。 */
export const EDITORIAL_SECTION_GAP: number = 18

/** 卡片列表之间的间距。 */
export const EDITORIAL_CARD_GAP: number = 12

/** 章节标题字号。 */
export const SECTION_TITLE_SIZE: number = 13

/** 页面级标题字号（如题库页顶部的「题库」）。 */
export const PAGE_TITLE_SIZE: number = 26

/** 章节标题右侧说明 / 动作的字号。 */
export const SECTION_DETAIL_SIZE: number = 12

/** 方形书签徽标的边长、圆角与字号。 */
export const BADGE_SIZE: number = 28
export const BADGE_RADIUS: number = 8
export const BADGE_GLYPH_SIZE: number = 13

/** 话题 / 学科 chips 的圆角（圆角矩形，不再是胶囊）。 */
export const CHIP_RADIUS: number = 14

/** 统计数字 / 统计标签的字号与竖细线高度。 */
export const STAT_VALUE_SIZE: number = 20
export const STAT_LABEL_SIZE: number = 12
export const STAT_RULE_HEIGHT: number = 30
