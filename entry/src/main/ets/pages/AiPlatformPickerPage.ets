import { BODY_FONT_SIZE, PAGE_PADDING, themePalette } from '../constants/AppTheme'
import { SHEET_RADIUS } from '../constants/EditorialStyle'
import { UiStyle } from '../constants/UiStyle'
import {
  AiPlatform, AiPlatformAccess, AiPlatformCatalog, AiPlatformCategory
} from '../models/ai/AiPlatformCatalog'
import { AppColors } from '../theme/AppColors'
import { AiPlatformSelectionState } from '../utils/AiPlatformSelectionState'
import { SafeAreaInsets, SafeAreaUtils } from '../utils/SafeAreaUtils'

class CategoryFilter {
  readonly key: string
  readonly label: string
  readonly category: AiPlatformCategory | null

  constructor(key: string, label: string, category: AiPlatformCategory | null) {
    this.key = key
    this.label = label
    this.category = category
  }
}

const FILTERS: Array<CategoryFilter> = [
  new CategoryFilter('all', '全部', null),
  new CategoryFilter('direct', '模型原厂', AiPlatformCategory.DIRECT),
  new CategoryFilter('inference', '推理平台', AiPlatformCategory.INFERENCE),
  new CategoryFilter('gateway', '聚合转发', AiPlatformCategory.AGGREGATOR),
  new CategoryFilter('cloud', '云平台', AiPlatformCategory.CLOUD),
  new CategoryFilter('local', '本地部署', AiPlatformCategory.LOCAL)
]

@Entry
@Component
struct AiPlatformPickerPage {
  @StorageProp('darkMode') darkMode: boolean = false
  @StorageProp('safeAreaInsets') safeAreaInsets: SafeAreaInsets = { top: 0, left: 0, right: 0, bottom: 0 }
  @State keyword: string = ''
  @State filterKey: string = 'all'

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  private activeCategory(): AiPlatformCategory | null {
    for (let index: number = 0; index < FILTERS.length; index++) {
      if (FILTERS[index].key === this.filterKey) return FILTERS[index].category
    }
    return null
  }

  // 无关键词时直接按分类取（避免先复制全部目录再过滤）；有关键词时用 search 命中 id/中英文名，
  // 两个条件同时存在时按分类收窄搜索结果。
  private visiblePlatforms(): Array<AiPlatform> {
    const category: AiPlatformCategory | null = this.activeCategory()
    if (this.keyword.trim().length === 0 && category !== null) {
      return AiPlatformCatalog.byCategory(category)
    }
    const matched: Array<AiPlatform> = AiPlatformCatalog.search(this.keyword)
    if (category === null) return matched
    const filtered: Array<AiPlatform> = new Array<AiPlatform>()
    for (let index: number = 0; index < matched.length; index++) {
      if (matched[index].category === category) filtered.push(matched[index])
    }
    return filtered
  }

  private tagFor(platform: AiPlatform): string {
    if (platform.access === AiPlatformAccess.GATEWAY) return '需自建网关'
    if (platform.access === AiPlatformAccess.LOCAL_HTTP) return '本机'
    return '云端模型'
  }

  // 副标题只在能补充信息时显示：nameEn 与 nameZh 相同、或 nameZh 已含 nameEn（如「深度求索 DeepSeek」）
  // 都会与主标题重复，返回空串由调用处跳过渲染。本地部署优先显示 baseUrl，优先级不变。
  private subtitleFor(platform: AiPlatform): string {
    if (platform.access === AiPlatformAccess.LOCAL_HTTP) return platform.baseUrl
    if (platform.nameZh.includes(platform.nameEn)) return ''
    return platform.nameEn
  }

  private goBack(): void {
    this.getUIContext().getRouter().back()
  }

  private resetFilters(): void {
    this.keyword = ''
    this.filterKey = 'all'
  }

  private choose(platform: AiPlatform): void {
    AiPlatformSelectionState.shared().select(platform.id)
    this.getUIContext().getRouter().back()
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        Button('返回')
          .type(ButtonType.Normal)
          .constraintSize({ minWidth: UiStyle.TOUCH_TARGET, minHeight: UiStyle.TOUCH_TARGET })
          .fontSize(UiStyle.DETAIL_SIZE)
          .fontColor(UiStyle.action(this.darkMode))
          .backgroundColor(this.colors().pageBackground)
          .accessibilityText('返回 AI 识别设置')
          .onClick(() => { this.goBack() })

        Text('选择 AI 平台')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.colors().textPrimary)
      }
      .width('100%')
      .constraintSize({ maxWidth: UiStyle.CONTENT_WIDTH, minHeight: UiStyle.TOUCH_TARGET })
      .padding({ left: PAGE_PADDING, right: PAGE_PADDING })

      Column({ space: UiStyle.FIELD_GAP }) {
        TextInput({ text: this.keyword, placeholder: '搜索平台名称，如 deepseek / 月之暗面' })
          .width('100%')
          .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
          .fontSize(UiStyle.BODY_SIZE)
          .fontColor(this.colors().textPrimary)
          .backgroundColor(this.colors().inputBackground)
          .border({ width: 1, color: this.colors().divider })
          .borderRadius(UiStyle.CONTROL_RADIUS)
          .accessibilityText('搜索 AI 平台')
          .onChange((value: string) => { this.keyword = value })

        Scroll() {
          Row({ space: 8 }) {
            ForEach(FILTERS, (item: CategoryFilter) => {
              Button(item.label)
                .type(ButtonType.Normal)
                .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
                .padding({ left: 16, right: 16 })
                .fontSize(UiStyle.DETAIL_SIZE)
                .backgroundColor(this.filterKey === item.key ?
                  UiStyle.action(this.darkMode) : this.colors().chipBackground)
                .fontColor(this.filterKey === item.key ?
                  UiStyle.onAction(this.darkMode) : this.colors().textPrimary)
                .borderRadius(UiStyle.CONTROL_RADIUS)
                .accessibilityText('平台分类：' + item.label)
                .accessibilitySelected(this.filterKey === item.key)
                .onClick(() => { this.filterKey = item.key })
            }, (item: CategoryFilter) => item.key)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')

        Row() {
          Text('匹配平台 ' + this.visiblePlatforms().length.toString() + ' 个')
            .fontSize(UiStyle.DETAIL_SIZE)
            .fontColor(this.colors().textCaption)
          Blank()
          if (this.keyword.length > 0 || this.filterKey !== 'all') {
            Button('清空筛选')
              .type(ButtonType.Normal)
              .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
              .fontSize(UiStyle.DETAIL_SIZE)
              .fontColor(UiStyle.action(this.darkMode))
              .backgroundColor(this.colors().pageBackground)
              .onClick(() => { this.resetFilters() })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.visiblePlatforms().length === 0) {
          Column({ space: 12 }) {
            Text('没有匹配的平台')
              .fontSize(UiStyle.BODY_SIZE)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.colors().textPrimary)
            Text('换一个关键词，或清空搜索与筛选后查看全部平台。')
              .fontSize(UiStyle.DETAIL_SIZE)
              .fontColor(this.colors().textCaption)
              .textAlign(TextAlign.Center)
              .lineHeight(22)
            Button('清空搜索与筛选')
              .type(ButtonType.Normal)
              .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
              .fontSize(UiStyle.DETAIL_SIZE)
              .fontColor(UiStyle.action(this.darkMode))
              .backgroundColor(this.colors().cardBackground)
              .border({ width: 1, color: UiStyle.action(this.darkMode) })
              .borderRadius(UiStyle.CONTROL_RADIUS)
              .onClick(() => { this.resetFilters() })
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        }
        else {
          List() {
            ForEach(this.visiblePlatforms(), (platform: AiPlatform) => {
              ListItem() {
                Row({ space: 12 }) {
                  Column({ space: 4 }) {
                    Text(platform.nameZh)
                      .fontSize(BODY_FONT_SIZE)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.colors().textPrimary)
                      .maxLines(2)
                    if (this.subtitleFor(platform).length > 0) {
                      Text(this.subtitleFor(platform))
                        .fontSize(12)
                        .fontColor(this.colors().textCaption)
                        .maxLines(2)
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  Text(this.tagFor(platform))
                    .fontSize(12)
                    .fontColor(UiStyle.action(this.darkMode))

                  Text('›')
                    .fontSize(22)
                    .fontColor(this.colors().textCaption)
                }
                .width('100%')
                .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .backgroundColor(this.colors().cardBackground)
              }
              .accessibilityText(platform.nameZh + '，' + this.tagFor(platform) + '，点击选择')
              .onClick(() => { this.choose(platform) })
            }, (platform: AiPlatform) => platform.id)
          }
          .layoutWeight(1)
          .width('100%')
          .backgroundColor(this.colors().cardBackground)
          .border({ width: 1, color: this.colors().divider })
          .borderRadius(SHEET_RADIUS)
          .divider({ strokeWidth: 1, color: this.colors().divider, startMargin: 16, endMargin: 16 })
          .scrollBar(BarState.Off)
        }
      }
      .layoutWeight(1)
      .width('100%')
      .constraintSize({ maxWidth: UiStyle.CONTENT_WIDTH })
      .padding({ top: 12, left: PAGE_PADDING, right: PAGE_PADDING, bottom: PAGE_PADDING })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
    .padding({
      top: SafeAreaUtils.top(this.safeAreaInsets),
      bottom: SafeAreaUtils.bottom(this.safeAreaInsets),
      left: SafeAreaUtils.left(this.safeAreaInsets),
      right: SafeAreaUtils.right(this.safeAreaInsets)
    })
  }
}
