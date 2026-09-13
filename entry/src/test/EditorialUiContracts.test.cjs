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
  const end = source.indexOf(to, start + from.length)
  if (end < 0) {
    throw new Error('required closing marker is missing: ' + to)
  }
  return source.slice(start, end)
}

// 2026-09-10 需求：题库 / 错题 / 我的三个 tab 页统一到首页已确认的「编辑 / 练习册风」。
// 这三页此前被 17 个合同钉住的是行为、文案、路由与回调，不是视觉；因此本次只改版式，
// 所有被钉住的 copy / 回调 / 键生成器 / 路由原样保留，视觉统一由下面的令牌与断言把住。

// 1. 共享编辑风令牌（单一事实来源，避免同一套比例在各页各写一遍）
const style = read('constants/EditorialStyle.ets')
for (const token of ['SHEET_RADIUS', 'HAIRLINE', 'EDITORIAL_SECTION_GAP', 'EDITORIAL_CARD_GAP',
  'SECTION_TITLE_SIZE', 'PAGE_TITLE_SIZE', 'BADGE_SIZE', 'BADGE_RADIUS', 'STAT_VALUE_SIZE',
  'STAT_RULE_HEIGHT']) {
  expectIncludes(style, 'export const ' + token, 'the editorial language must export ' + token)
}
expectIncludes(style, 'SHEET_RADIUS: number = 16', 'paper sheets must keep radius 16')
expectIncludes(style, 'HAIRLINE: number = 1', 'dividers must stay 1px hairlines')

// 2. 章节标题：13px Bold + letterSpacing(1) + 细线（首页 HomeRecentSection 已建立的排版）
const sectionTitle = read('components/SectionTitle.ets')
expectIncludes(sectionTitle, 'SECTION_TITLE_SIZE', 'section titles must use the shared title size')
expectIncludes(sectionTitle, '.letterSpacing(1)', 'section titles must keep the editorial letter spacing')
expectIncludes(sectionTitle, 'HAIRLINE', 'section titles must rule a hairline')
expectIncludes(sectionTitle, 'Divider()', 'section titles must close with a hairline rule')

// 3. 纸张卡片：圆角 16 + 1px divider 描边 + 品牌绿软底强调，去掉旧的 20px 圆角与灰底胶囊
for (const relative of ['components/QuestionBankCard.ets', 'components/WrongQuestionCard.ets']) {
  const source = read(relative)
  expectIncludes(source, 'SHEET_RADIUS', relative + ' must render as an editorial paper sheet')
  expectIncludes(source, 'border({ width: HAIRLINE, color: this.colors().divider })',
    relative + ' must be outlined with a hairline instead of relying on fill alone')
  expectIncludes(source, 'brandSoft', relative + ' must use brand-soft accents')
  expectAbsent(source, 'CARD_RADIUS', relative + ' must not keep the legacy 20px card radius')
}

// 4. 统计：一张纸 + 竖细线分隔（与首页概览卡底部三统计同一套比例），不再用旧 StatCard 网格
const statRow = read('components/StatRow.ets')
expectIncludes(statRow, 'SHEET_RADIUS', 'the stat sheet must share the paper radius')
expectIncludes(statRow, 'HAIRLINE', 'the stat sheet must separate cells with hairlines')
expectIncludes(statRow, 'STAT_VALUE_SIZE', 'the stat sheet must use the shared stat value size')
expectIncludes(statRow, 'divider', 'the stat rules must use the theme divider colour')

const wrongs = read('pages/WrongQuestionsPage.ets')
expectIncludes(wrongs, 'StatRow({', 'wrong-question statistics must use the shared editorial stat sheet')
expectAbsent(wrongs, 'StatCard({', 'wrong-question statistics must not keep the legacy stat cards')
expectIncludes(wrongs, 'brandSoft', 'subject chips must use the brand-soft accent')
expectIncludes(wrongs, "SectionTitle({", 'wrong questions must open a section with the editorial head')
expectIncludes(wrongs, "import { StatRow, StatCell } from '../components/StatRow'",
  'the wrong-question page must import the shared stat sheet')

const mine = read('pages/MinePage.ets')
expectIncludes(mine, 'StatRow({', 'the study overview must use the shared editorial stat sheet')
expectAbsent(mine, 'StatCard({', 'the study overview must not keep the legacy stat cards')
expectIncludes(mine, "import { StatRow, StatCell } from '../components/StatRow'",
  'the mine page must import the shared stat sheet')

// 5. 我的：学习中心身份并入账号纸卡；设置 / 开发辅助行继续使用方形书签 + 行间细线。
const accountCard = read('components/HuaweiAccountCard.ets')
expectIncludes(accountCard, "Text('学习中心')", 'the account sheet must host the learning-center identity')
expectIncludes(accountCard, "Text('整理错题，让每次复习更有方向')",
  'the merged account sheet must keep the learning purpose')
expectIncludes(accountCard, 'Divider()', 'the merged identity and account state must use a hairline divider')
expectIncludes(accountCard, 'SHEET_RADIUS', 'the merged learning/account module must remain a paper sheet')
expectIncludes(accountCard, 'border({ width: HAIRLINE, color: this.colors().divider })',
  'the merged learning/account module must be outlined with a hairline')

const settings = slice(mine, 'private SettingsSection()', 'private DebugToolsSection()')
expectIncludes(settings, 'Divider()', 'settings rows must be separated by hairlines')
expectIncludes(settings, 'this.SettingRow(', 'settings rows must use the shared editorial row')
expectIncludes(settings, "SectionTitle({ title: '设置' })", 'the settings head must stay pinned')

const settingRow = slice(mine, 'private SettingRow(', 'private SettingsSection()')
expectIncludes(settingRow, 'BADGE_SIZE', 'settings rows must use the editorial square badge')
expectIncludes(settingRow, 'BADGE_RADIUS', 'settings badges must use the shared badge radius')
expectIncludes(settingRow, 'brandSoft', 'settings badges must use the brand-soft fill')
expectAbsent(settingRow, '.borderRadius(18)', 'settings badges must not stay circular')

const debug = slice(mine, 'private DebugToolsSection()', '  build() {')
expectIncludes(debug, "SectionTitle({ title: '开发辅助' })", 'the developer head must stay pinned')
expectIncludes(debug, 'SHEET_RADIUS', 'the developer sheet must share the paper radius')
expectIncludes(debug, 'border({ width: HAIRLINE, color: this.colors().divider })',
  'the developer sheet must be outlined with a hairline')
expectIncludes(debug, 'BADGE_SIZE', 'developer rows must use the editorial square badge')
expectIncludes(debug, 'BADGE_RADIUS', 'developer rows must use the shared badge radius')

// 6. 空态：方形书签章 + 描边次级按钮（与首页「导入资料」次级操作一致）
const empty = read('components/EmptyState.ets')
expectIncludes(empty, 'brandSoft', 'the empty-state badge must use the brand-soft fill')
expectIncludes(empty, 'border({ width: HAIRLINE, color: this.colors().brand })',
  'the empty-state action must be an outlined secondary button')
expectAbsent(empty, '.borderRadius(32)', 'the empty-state badge must not stay circular')

// 7. 三个 tab 页面都必须引用共享令牌
for (const relative of ['pages/BooksPage.ets', 'pages/WrongQuestionsPage.ets', 'pages/MinePage.ets']) {
  const source = read(relative)
  expectIncludes(source, "from '../constants/EditorialStyle'",
    relative + ' must share the editorial language instead of re-declaring it')
}
// 7a. 2026-09-10 需求收敛（用户原话：「把题库里的全部题库四个字删掉，然后将题库移到最上面，跟消息栏留出距离」
//     → 随后补充：「把题库移到最上面，然后下面是内容」）：
//     题库页的结构确定为 —— 顶部页面级标题「题库」（让开系统状态栏），下面才是内容（图书列表）。
//     改写原因：上一版撤掉「全部题库」章节头后把列表直接顶到最上方，漏掉了页面标题；
//     本次补上页面级标题，并把「标题在上、内容在下」的顺序钉住。
const booksPage = read('pages/BooksPage.ets')
expectAbsent(booksPage, '全部题库', 'the books page must drop the 全部题库 section head copy')
expectAbsent(booksPage, 'SectionTitle(', 'the books page must not mount a section head')
expectIncludes(booksPage, 'PAGE_TITLE_SIZE', 'the page title must use the shared page-title size')
expectIncludes(booksPage, "Text('题库')", 'the books page must render its own 题库 page title')
expectIncludes(booksPage, 'this.PageTitle()', 'the page title builder must be mounted in the feed')
expectIncludes(booksPage, 'BOOKS_FEED_TOP_GAP',
  'the books list must keep its own top breathing gap constant')
expectIncludes(booksPage, 'SafeAreaUtils.top(this.safeAreaInsets) + BOOKS_FEED_TOP_GAP',
  'the page must clear the real status-bar inset plus a breathing gap')
expectIncludes(booksPage, 'top: this.booksTopGap()', 'the feed must apply the adaptive top gap')
const booksTitleAt = booksPage.indexOf('this.PageTitle()')
const booksContentAt = booksPage.indexOf('this.BankCard(bank)')
if (!(booksTitleAt >= 0 && booksContentAt > booksTitleAt)) {
  throw new Error('the 题库 page title must be mounted above the bank cards')
}

// 7a-2. 真机实测（192.168.0.104:35914 平板分栏窗口）：同一标题带里出现了两簇「题库」——
//       x[38..148]（系统标题栏 / 分栏侧栏镜像 App 的 Navigation 标题）与 x[322..424]（本页页头）。
//       结论：题库页的标题由页面自己渲染（各窗口模式都存在），因此题库 tab 的 Navigation 标题留空，
//       与首页同一做法，避免出现两个「题库」。
const booksHost = read('pages/Index.ets')
assert.match(booksHost,
  /private titleFor\(index: number\): string \{\s*if \(index === MainTabIndex\.BOOKS\) \{\s*(?:\/\/[^\n]*\n\s*)?return ''/,
  'the books tab must leave the Navigation title empty so only the in-page 题库 header shows')

// 7b. 我的页里嵌的账号卡与旧数据迁移卡也必须走同一套纸张语言
for (const relative of ['components/HuaweiAccountCard.ets', 'components/LegacyMigrationCard.ets']) {
  const source = read(relative)
  expectIncludes(source, 'SHEET_RADIUS', relative + ' must use the shared paper radius')
  expectIncludes(source, 'border({ width: HAIRLINE, color: this.colors().divider })',
    relative + ' must be outlined with a hairline')
  expectAbsent(source, 'CARD_RADIUS', relative + ' must drop the legacy card radius')
}

// 7c. 旧的统计卡片组件已被共享 StatRow 取代，不应留下死代码
if (fs.existsSync(path.join(etsRoot, 'components', 'StatCard.ets'))) {
  throw new Error('components/StatCard.ets must be deleted once the editorial StatRow replaces it')
}

// 8. 首页三件套也改用同一份令牌（同一套比例的唯一来源）
for (const relative of ['pages/HomePage.ets', 'components/HomeOverviewCard.ets',
  'components/HomeRecentSection.ets']) {
  expectIncludes(read(relative), "constants/EditorialStyle",
    relative + ' must consume the shared editorial tokens')
}

process.stdout.write('Editorial UI contracts passed\n')
