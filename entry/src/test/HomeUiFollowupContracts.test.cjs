const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const root = path.resolve(__dirname, '../main/ets')
const read = relative => fs.readFileSync(path.join(root, relative), 'utf8')

function section(source, from, to) {
  const start = source.indexOf(from)
  assert.notEqual(start, -1, `missing section: ${from}`)
  const end = source.indexOf(to, start + from.length)
  assert.notEqual(end, -1, `missing section end: ${to}`)
  return source.slice(start, end)
}

test('home keeps one import entry and names every shortcut for its real destination', () => {
  const home = read('pages/HomePage.ets')
  const quick = section(home, 'private QuickEntryRow()', 'private StatusBanner()')
  for (const label of ['AI 设置', '查看题库', '查看错题']) {
    assert.ok(quick.includes(`'${label}'`), `missing truthful shortcut label: ${label}`)
  }
  for (const misleading of ['导入题库', 'AI 识别', '错题复习', '我的题库', '我的错题']) {
    assert.ok(!quick.includes(`'${misleading}'`), `legacy shortcut remains: ${misleading}`)
  }
  assert.doesNotMatch(home, /private ImportButton\(\)/)
  assert.doesNotMatch(home, /private TopicChipStrip\(\)/)
  assert.doesNotMatch(home, /class HomeTopicChip/)
  assert.match(home, /title: '暂无学习数据'[\s\S]{0,360}?actionLabel: '导入资料'/)

  const index = read('pages/Index.ets')
  assert.match(index, /this\.TabBarImportAction\(\)/)
  assert.match(index, /url: 'pages\/ImportBankPage'/)
})

test('recent summaries expose one list-level action and rows no longer pretend to deep-link', () => {
  const recent = read('components/HomeRecentSection.ets')
  assert.match(recent, /@Prop actionLabel: string = '查看列表'/)
  assert.match(recent, /onViewAll: \(\) => void/)
  const head = section(recent, 'private SectionHead()', '  build()')
  assert.match(head, /Button\(this\.actionLabel\)/)
  assert.match(head, /\.height\(48\)/)
  assert.match(head, /this\.onViewAll\(\)/)
  assert.doesNotMatch(recent, /onOpen: \(index: number\)/)
  assert.doesNotMatch(recent, /this\.onOpen\(index\)/)
  assert.doesNotMatch(recent, /Text\('›'\)/)

  const home = read('pages/HomePage.ets')
  assert.match(home, /title: '最近书籍'[\s\S]{0,220}?actionLabel: '查看题库列表'/)
  assert.match(home, /title: '最近错题'[\s\S]{0,220}?actionLabel: '查看错题列表'/)
})

test('home shortcuts and primary review meet touch size and large-text layout contracts', () => {
  const home = read('pages/HomePage.ets')
  const quick = section(home, 'private QuickEntry(', 'private QuickEntryRow()')
  assert.match(quick, /\.width\(48\)/)
  assert.match(quick, /\.height\(48\)/)
  assert.match(quick, /\.constraintSize\(\{ minHeight: 80 \}\)/)
  assert.match(quick, /\.maxLines\(2\)/)
  assert.match(quick, /\.textAlign\(TextAlign\.Center\)/)
  assert.match(home, /left: PAGE_PADDING \+ SafeAreaUtils\.left\(this\.safeAreaInsets\)/)
  assert.match(home, /right: PAGE_PADDING \+ SafeAreaUtils\.right\(this\.safeAreaInsets\)/)

  const overview = read('components/HomeOverviewCard.ets')
  assert.match(overview, /\.height\(48\)/)
  const index = read('pages/Index.ets')
  const importAction = section(index, 'private TabBarImportAction()', 'private TabContents()')
  assert.equal((importAction.match(/\.width\(48\)/g) || []).length, 2)
  assert.equal((importAction.match(/\.height\(48\)/g) || []).length, 2)
  assert.match(importAction, /\.accessibilityText\('导入题库'\)/)
  assert.match(importAction,
    /\.onTouch\(\(event: TouchEvent\) => \{\s*event\.stopPropagation\(\)\s*\}\)[\s\S]*?\.onClick\(\(\) => \{\s*this\.openImportPage\(\)\s*\}\)/,
    'the import action must consume touch bubbling before routing so HdsTabs cannot animate to the action slot')
})

test('HdsTabs action-slot mapping and guarded navigation remain intact', () => {
  const index = read('pages/Index.ets')
  for (const contract of [
    '.scrollable(false)',
    'position === MainTabBarPosition.IMPORT',
    'this.tabsController.changeIndex(this.tabBarIndex)',
    'if (this.navigationPending)',
    'this.navigationPending = true',
    "url: 'pages/AiRecognitionSettingsPage'"
  ]) {
    assert.ok(index.includes(contract), `navigation contract missing: ${contract}`)
  }

  const changeHandler = section(index, '.onChange((position: number) => {', ".width('100%')")
  const importBranch = section(changeHandler,
    'if (position === MainTabBarPosition.IMPORT) {', 'this.selectTab(this.tabIndexForPosition(position))')
  assert.doesNotMatch(importBranch, /this\.openImportPage\(\)/,
    'the HdsTabs selection callback must not push a second copy of the import page')
})
