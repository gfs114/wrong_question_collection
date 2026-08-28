export enum MainTabIndex {
  HOME = 0,
  BOOKS = 1,
  WRONG_QUESTIONS = 2,
  MINE = 3
}

export class MainTab {
  index: MainTabIndex
  label: string

  constructor(index: MainTabIndex, label: string) {
    this.index = index
    this.label = label
  }
}
