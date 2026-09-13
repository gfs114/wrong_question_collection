const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')

const etsRoot = path.resolve(__dirname, '../main/ets')

function read(relativePath) {
  const file = path.join(etsRoot, relativePath)
  if (!fs.existsSync(file)) {
    throw new Error(relativePath + ' is required')
  }
  return fs.readFileSync(file, 'utf8')
}

function expectIncludes(source, text, message) {
  if (!source.includes(text)) {
    throw new Error(message + ': ' + text)
  }
}

function expectAbsent(source, text, message) {
  if (source.includes(text)) {
    throw new Error(message + ': ' + text)
  }
}

function slice(source, from, to) {
  const start = source.indexOf(from)
  if (start < 0) {
    throw new Error('required builder is missing: ' + from)
  }
  return source.slice(start, source.indexOf(to, start))
}

const page = read('pages/HomePage.ets')
const overview = read('components/HomeOverviewCard.ets')
const recent = read('components/HomeRecentSection.ets')

expectIncludes(page, "@Prop @Watch('onActiveChanged') active", 'home must load only while active')
expectIncludes(page, "@Prop @Watch('onRefreshVersionChanged') refreshVersion", 'home must refresh after mutations')
expectIncludes(page, 'CloudQuestionRepository.statistics', 'home must load the dashboard from the cloud cache')
expectIncludes(page, 'CloudQuestionRepository.listCachedBanks', 'home must list recent books from the cache')
expectIncludes(page, 'CloudQuestionRepository.listCachedWrongQuestions', 'home must list recent wrong questions from the cache')
expectIncludes(page, 'requestToken', 'home must reject stale async results')
expectIncludes(page, '今日待复习', 'home must show today review work')
expectIncludes(page, '错题总数', 'home must show wrong-question totals')
expectIncludes(page, '已掌握', 'home must show mastered totals')
expectIncludes(page, '掌握率', 'home must show mastery rate')
expectIncludes(page, '最近书籍', 'home must show recent books')
expectIncludes(page, '最近错题', 'home must show recent wrong questions')
expectIncludes(page, '开始复习', 'home must expose review action')
expectIncludes(page, '导入资料', 'home must expose import action')
expectIncludes(page, '暂无学习数据', 'home must provide a real empty state')
expectIncludes(overview, '.backgroundColor(this.colors().cardBackground)',
  'the primary dashboard card must use the theme card background')
expectIncludes(recent, 'items.length === 0', 'recent sections must render empty data explicitly')

// 2026-09-12 H1：首页入口收敛。导入由底栏中间动作承担，空数据时保留情境化 CTA；
// 快捷区只保留真实目的地，摘要内容不再伪装成详情直达入口。
expectIncludes(page, 'this.QuickEntryRow()', 'home must mount the quick-entry row')
expectIncludes(page, 'this.onOpenAiSettings()', 'the quick entries must reach the AI settings page')
expectIncludes(page, "'AI 设置'", 'the AI shortcut must name its actual destination')
expectIncludes(page, "'查看题库'", 'the books shortcut must name its list destination')
expectIncludes(page, "'查看错题'", 'the wrong-question shortcut must name its list destination')
expectAbsent(page, 'private TopicChipStrip()', 'misleading data chips must be removed')
expectAbsent(page, 'class HomeTopicChip', 'misleading data chip models must be removed')
expectAbsent(page, 'private ImportButton()', 'the duplicate home import button must be removed')
expectIncludes(page, "$r('sys.symbol.wand_and_stars')", 'the AI entry must use a verified system symbol')
expectIncludes(page, "$r('sys.symbol.books_vertical_fill')", 'the books entry must use a verified system symbol')
expectIncludes(page, "$r('sys.symbol.exclamationmark_circle_fill')",
  'the wrong-question entry must use a verified system symbol')
// 2026-09-10：首页不显示标题后，内容整体下移；顶部让位改由真实窗口避让区提供（见下方改写 5）。
expectIncludes(page, 'HOME_FEED_TOP_GAP', 'the home feed must keep its top gap constant')

// 2026-09-10 首页 UI 全重构（已确认方向 A：编辑 / 练习册风）。
// 结构断言随实现同步改写；被改写的旧断言在下方逐条注明原因。
// 改写 1：chips 底色由 colors().chipBackground（浅蓝 #EEF5FF）改为 colors().brandSoft，
//         原因 = 首页色调统一为品牌绿；error 红只保留给「待复习」数字；chipBackground 仍留在 AI 设置页。
// 改写 4（已被改写 5 取代，保留过程记录）：曾经把 HOME_FEED_TOP_GAP 由 12 调到 68。当时的依据是
//         状态栏「窗口」矩形 116px = 58vp（WEB-W00，密度 2.0px/vp）。
// 改写 5（本次）：不再写死机型数值。68 换成「纯呼吸间距 10」，顶部让位改由窗口真实避让区提供：
//         `SafeAreaUtils.top(this.safeAreaInsets) + HOME_FEED_TOP_GAP`。
//         原因 = 用户要求「换机型/换窗口模式都自动避让」。
//         真机复核（把呼吸间距临时置 0 作为探针）：避让区实测 = 78px = 39vp，与系统块
//         SCBGestureTopBar [0 0 2880 78] 一致 —— 它比状态栏窗口矩形(116px)小，所以原先按 58vp
//         硬编码其实是偏大的估计。最终 39 + 10 = 49vp：日期行墨迹实测 180px，与推演逐像素吻合。
expectIncludes(page, 'HOME_FEED_TOP_GAP: number = 10',
  'the constant must be pure breathing room, not a device-specific status bar height')
expectIncludes(page, 'SafeAreaUtils.top(this.safeAreaInsets) + HOME_FEED_TOP_GAP',
  'the feed top must be the real window avoid area plus breathing room')
expectIncludes(page, 'top: this.topGap()',
  'the feed (and the status banner wrappers) must apply the adaptive top gap')
expectIncludes(page, "@StorageProp('safeAreaInsets') safeAreaInsets: SafeAreaInsets",
  'the home page must bind the published safe-area insets')
expectIncludes(page, 'EDITORIAL_SECTION_GAP',
  'the editorial feed must define its own section gap constant')
expectIncludes(page, 'List({ space: EDITORIAL_SECTION_GAP })',
  'the feed list must space items with the editorial gap')
expectIncludes(page, 'HAIRLINE', 'the masthead must share the editorial hairline token')
assert.match(page, /todayLabel\(\): string \{[\s\S]{0,240}?new Date\(\)[\s\S]{0,240}?getDay\(\)/,
  'the masthead must build its date line from the local clock and a local weekday table')
expectIncludes(page, 'WEEKDAYS', 'the masthead must not pull in a new dependency for weekday names')

const masthead = slice(page, 'private Masthead()', 'private QuickEntry(')
expectIncludes(masthead, "'今日'", 'the masthead must lead with the editorial 今日 heading')
expectIncludes(masthead, 'this.todayLabel()', 'the masthead must show the local date line')
expectIncludes(masthead, '.letterSpacing(1)',
  'the masthead date line must keep the editorial letter spacing (章节标题同一套排版)')
expectIncludes(masthead, 'this.syncLabel', 'the masthead must keep the sync label')
expectIncludes(masthead, 'backgroundColor(this.colors().brandSoft)',
  'the sync label must render as a brand-soft capsule')
expectIncludes(masthead, 'Divider()', 'the masthead must close with a hairline rule')
expectIncludes(page, 'this.Masthead()', 'the masthead must replace the greeting block in the feed')
expectAbsent(page, "'今天也要稳稳进步'", 'the greeting block must be replaced by the masthead')

// 顶部安全区：loading / error 分支的首个元素也是 StatusBanner，同样必须让开状态栏，
// 因此这两处的横幅要用一个带顶部留白的 Column 包住（信息流内的那份已由 List 的 padding 负责）。
const bannerWrappers = (page.match(/Column\(\) \{\s*this\.StatusBanner\(\)\s*\}/g) || []).length
assert.equal(bannerWrappers, 2,
  'the loading and error branches must wrap the status banner so it clears the status bar')

// H1：三项快捷入口保留圆角方形，并达到 48vp 触控与两行大字布局要求。
const quickEntry = slice(page, 'private QuickEntry(', 'private QuickEntryRow()')
expectIncludes(quickEntry, 'borderRadius(14)', 'quick entries must be rounded squares')
expectAbsent(quickEntry, 'borderRadius(23)', 'quick entries must not stay circular')
expectIncludes(quickEntry, '.width(48)', 'quick-entry glyph target must reach 48vp')
expectIncludes(quickEntry, '.height(48)', 'quick-entry glyph target must reach 48vp')
expectIncludes(quickEntry, '.maxLines(2)', 'quick-entry labels must survive large text')
expectIncludes(quickEntry, '.constraintSize({ minHeight: 80 })',
  'the full quick-entry target must remain comfortably tappable')

expectIncludes(recent, "@Prop actionLabel: string = '查看列表'",
  'recent sections must expose a truthful list-level action')
expectIncludes(recent, 'onViewAll: () => void', 'recent sections must use one list-level callback')
expectAbsent(recent, 'onOpen: (index: number)', 'summary rows must not pretend to deep-link')
expectAbsent(recent, "Text('›')", 'summary rows must not show a detail chevron')

const indexPage = read('pages/Index.ets')
expectIncludes(indexPage, 'onOpenAiSettings:', 'index must wire the AI settings entry')
expectIncludes(indexPage, "'pages/AiRecognitionSettingsPage'", 'the AI entry must route to the settings page')

process.stdout.write('Home page contracts passed\n')
