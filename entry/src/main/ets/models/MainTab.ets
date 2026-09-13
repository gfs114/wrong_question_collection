export enum MainTabIndex {
  HOME = 0,
  BOOKS = 1,
  WRONG_QUESTIONS = 2,
  MINE = 3
}

/**
 * 底栏槽位（含中间「+」动作位）。槽位顺序与 MainTabIndex 解耦：
 * 0=HOME、1=BOOKS、2=IMPORT（动作位，不是可停留的 Tab）、3=WRONG_QUESTIONS、4=MINE。
 */
export class MainTabBarPosition {
  static readonly HOME: number = 0
  static readonly BOOKS: number = 1
  static readonly IMPORT: number = 2
  static readonly WRONG_QUESTIONS: number = 3
  static readonly MINE: number = 4
}

export class MainTab {
  index: MainTabIndex
  label: string

  constructor(index: MainTabIndex, label: string) {
    this.index = index
    this.label = label
  }
}
