/** 首批导入与设置页的展示令牌；不改变全局主题和业务状态。 */
export class UiStyle {
  static readonly CONTENT_WIDTH: number = 680
  static readonly TOUCH_TARGET: number = 48
  static readonly GROUP_GAP: number = 24
  static readonly FIELD_GAP: number = 16
  static readonly CONTROL_RADIUS: number = 12
  static readonly BODY_SIZE: number = 16
  static readonly DETAIL_SIZE: number = 14

  static action(dark: boolean): string {
    return dark ? '#3ECF93' : '#087A54'
  }

  static onAction(dark: boolean): string {
    return dark ? '#072B1E' : '#FFFFFF'
  }

  static errorText(dark: boolean): string {
    return dark ? '#FF8A8A' : '#B42332'
  }
}
