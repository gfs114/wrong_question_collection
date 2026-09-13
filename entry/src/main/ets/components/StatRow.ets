import {
  HAIRLINE,
  SHEET_RADIUS,
  STAT_LABEL_SIZE,
  STAT_RULE_HEIGHT,
  STAT_VALUE_SIZE
} from '../constants/EditorialStyle'
import { themePalette } from '../constants/AppTheme'
import { AppColors } from '../theme/AppColors'

/** 编辑风统计条的一格：标签 + 数值 + 强调色。 */
export class StatCell {
  readonly label: string
  readonly value: string
  readonly accent: string

  constructor(label: string, value: string, accent: string) {
    this.label = label
    this.value = value
    this.accent = accent
  }
}

/**
 * 统计条：一张纸张卡片内用竖细线分隔若干格，与首页概览卡底部三统计同一套比例。
 * 数字只强调一处（调用方用 error / successText 决定），其余走 textPrimary。
 */
@Component
export struct StatRow {
  @Prop cells: Array<StatCell> = new Array<StatCell>()
  @StorageProp('darkMode') darkMode: boolean = false

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  @Builder
  private Cell(cell: StatCell, showRule: boolean) {
    Row() {
      if (showRule) {
        Column()
          .width(HAIRLINE)
          .height(STAT_RULE_HEIGHT)
          .backgroundColor(this.colors().divider)
          .margin({ right: 14 })
      }

      Column({ space: 4 }) {
        Text(cell.value)
          .fontSize(STAT_VALUE_SIZE)
          .fontWeight(FontWeight.Bold)
          .fontColor(cell.accent)

        Text(cell.label)
          .fontSize(STAT_LABEL_SIZE)
          .fontColor(this.colors().textCaption)
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Row() {
      ForEach(this.cells, (cell: StatCell, index: number) => {
        this.Cell(cell, index > 0)
      }, (cell: StatCell, index: number): string => cell.label + index.toString())
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 16 })
    .borderRadius(SHEET_RADIUS)
    .backgroundColor(this.colors().cardBackground)
    .border({ width: HAIRLINE, color: this.colors().divider })
  }
}
