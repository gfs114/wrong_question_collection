const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const etsRoot = path.resolve(__dirname, '../main/ets')

function read(relativePath) {
  return fs.readFileSync(path.join(etsRoot, relativePath), 'utf8')
}

function slice(source, from, to) {
  const start = source.indexOf(from)
  assert.notEqual(start, -1, `missing start marker: ${from}`)
  const end = source.indexOf(to, start + from.length)
  assert.notEqual(end, -1, `missing end marker: ${to}`)
  return source.slice(start, end)
}

test('wrong-question subject filters provide a readable 48vp selected control', () => {
  const page = read('pages/WrongQuestionsPage.ets')
  const chip = slice(page, 'private SubjectChip(', 'private StatusBanner()')

  assert.match(chip, /constraintSize\(\{ minHeight: 48 \}\)/)
  assert.match(chip, /maxLines\(2\)/)
  assert.match(chip, /accessibilitySelected\(selected\)/)
  assert.match(chip, /enabled\(!this\.loading\)/)
  assert.match(chip, /this\.selectSubject\(value\)/)
})

test('shared empty state supports page and embedded layouts without a fixed wrong-page box', () => {
  const empty = read('components/EmptyState.ets')
  const page = read('pages/WrongQuestionsPage.ets')

  assert.match(empty, /@Prop fillAvailable: boolean = true/)
  assert.match(empty, /constraintSize\(\{ minHeight: this\.emptyStateMinHeight\(\) \}\)/)
  assert.match(empty, /private emptyStateMinHeight\(\): Length/)
  assert.match(page, /fillAvailable: false/)
  assert.doesNotMatch(page, /\.height\(260\)/)
})

test('wrong-question and mine feeds include the live left and right safe-area insets', () => {
  for (const relative of ['pages/WrongQuestionsPage.ets', 'pages/MinePage.ets']) {
    const source = read(relative)
    assert.match(source, /SafeAreaInsets, SafeAreaUtils/)
    assert.match(source, /@StorageProp\('safeAreaInsets'\) safeAreaInsets: SafeAreaInsets/)
    assert.match(source, /left: PAGE_PADDING \+ SafeAreaUtils\.left\(this\.safeAreaInsets\)/)
    assert.match(source, /right: PAGE_PADDING \+ SafeAreaUtils\.right\(this\.safeAreaInsets\)/)
  }
})

test('mine separates ordinary settings from the confirmed destructive action', () => {
  const page = read('pages/MinePage.ets')
  const settings = slice(page, 'private SettingsSection()', 'private DataManagementSection()')
  const data = slice(page, 'private DataManagementSection()', 'private DebugToolsSection()')

  assert.doesNotMatch(settings, /'数据管理'/)
  assert.doesNotMatch(settings, /this\.confirmClear\(\)/)
  assert.match(data, /SectionTitle\(\{ title: '数据与隐私' \}\)/)
  assert.match(data, /永久删除当前账号的全部错题记录/)
  assert.match(data, /this\.confirmClear\(\)/)
  assert.match(data, /accessibilityText\('清空错题，永久删除当前账号的全部错题记录'\)/)

  assert.match(page, /title: '清空全部错题？'/)
  assert.match(page, /CloudQuestionRepository\.clearWrongQuestions\(hostContext\)/)
})

test('account and migration actions meet the 48vp touch-target floor', () => {
  const account = read('components/HuaweiAccountCard.ets')
  const migration = read('components/LegacyMigrationCard.ets')

  assert.doesNotMatch(account, /\.height\(46\)/)
  assert.match(account, /Button\(this\.syncing \? '正在同步…' : '立即同步'\)[\s\S]*?\.height\(48\)/)
  assert.match(account, /Button\('退出登录'\)[\s\S]*?\.height\(48\)/)
  assert.doesNotMatch(migration, /\.height\(44\)/)
  assert.equal((migration.match(/\.height\(48\)/g) || []).length >= 2, true)
})

test('wrong and mine own their top titles below the live status-bar inset', () => {
  const index = read('pages/Index.ets')
  const pages = [
    { path: 'pages/WrongQuestionsPage.ets', label: '错题' },
    { path: 'pages/MinePage.ets', label: '我的' }
  ]

  assert.match(index,
    /if \(index === MainTabIndex\.WRONG_QUESTIONS\)[\s\S]{0,160}?return ''/)
  assert.match(index,
    /if \(index === MainTabIndex\.MINE\)[\s\S]{0,160}?return ''/)

  for (const page of pages) {
    const source = read(page.path)
    const title = slice(source, 'private PageTitle()', '  build() {')
    const build = source.slice(source.indexOf('  build() {'))
    assert.match(source, /PAGE_TITLE_SIZE/)
    assert.match(source,
      /return SafeAreaUtils\.top\(this\.safeAreaInsets\) \+ [A-Z_]+_FEED_TOP_GAP/)
    assert.match(title, new RegExp(`Text\\('${page.label}'\\)`))
    assert.match(title, /\.fontSize\(PAGE_TITLE_SIZE\)/)
    assert.match(title, /Divider\(\)/)
    assert.match(build, /this\.PageTitle\(\)[\s\S]*if \(this\.loading\)/)
    assert.match(build, /top: this\.pageTopGap\(\)/)
  }
})

test('mine merges the learning-center identity into one account sheet', () => {
  const mine = read('pages/MinePage.ets')
  const account = read('components/HuaweiAccountCard.ets')
  const build = mine.slice(mine.indexOf('  build() {'))

  assert.doesNotMatch(mine, /private HeaderCard\(\)/)
  assert.doesNotMatch(build, /this\.HeaderCard\(\)/)
  assert.match(mine, /private LearningAccountSection\(\)/)
  assert.doesNotMatch(mine, /SectionTitle\(\{ title: '学习与账号' \}\)/)
  assert.match(build, /this\.LearningAccountSection\(\)/)
  const accountAt = build.indexOf('this.LearningAccountSection()')
  const overviewAt = build.indexOf('this.StatsSection()')
  assert.equal(accountAt >= 0 && overviewAt > accountAt, true,
    'the merged account sheet must sit directly below 我的 and before 学习概览')

  assert.match(account, /Text\('学习中心'\)/)
  assert.match(account, /Text\('整理错题，让每次复习更有方向'\)/)
  assert.match(account, /Divider\(\)/)
  assert.match(account, /Text\('已登录华为账号'\)/)
  assert.match(account, /Text\('登录后开启云同步'\)/)
})

test('mine displays the current hardware name without changing the login exchange boundary', () => {
  const mine = read('pages/MinePage.ets')
  const deviceName = slice(mine, 'private currentDeviceName(): string', 'private LearningAccountSection()')
  const accountSection = slice(mine, 'private LearningAccountSection()', 'private StatsSection()')

  assert.match(mine, /import deviceInfo from '@ohos\.deviceInfo'/)
  assert.match(deviceName, /deviceInfo\.marketName\.trim\(\)/)
  assert.match(deviceName, /deviceInfo\.productModel\.trim\(\)/)
  assert.match(deviceName, /return 'HarmonyOS 设备'/)
  assert.match(accountSection, /deviceName: this\.currentDeviceName\(\)/)
  assert.match(mine,
    /HuaweiLoginService\.exchange\(hostContext, authorizationCode, 'HarmonyOS device'\)/)
})
