const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const { stripTypeScriptTypes } = require('node:module')

const root = path.resolve(__dirname, '../main/ets')
const read = name => fs.readFileSync(path.join(root, name), 'utf8')
const pages = ['ImportBankPage', 'AiRecognitionSettingsPage', 'AiPlatformPickerPage']
function luminance(hex) {
  return hex.replace('#', '').match(/../g).map(x => parseInt(x, 16) / 255)
    .map(x => x <= .04045 ? x / 12.92 : ((x + .055) / 1.055) ** 2.4)
    .reduce((sum, x, i) => sum + x * [.2126, .7152, .0722][i], 0)
}
function contrast(a, b) {
  const values = [luminance(a), luminance(b)].sort((a, b) => b - a)
  return (values[0] + .05) / (values[1] + .05)
}
function styleRuntime() {
  const source = read('constants/UiStyle.ets').replace(/export /g, '')
  return vm.runInNewContext(stripTypeScriptTypes(source, { mode: 'transform' }) + '\nUiStyle')
}

test('primary and selected controls use readable light and dark color pairs', () => {
  for (const dark of [false, true]) {
    // Before remediation the pages use the palette brand/onBrand pair.
    const styleExists = fs.existsSync(path.join(root, 'constants/UiStyle.ets'))
    const old = read(`theme/${dark ? 'Dark' : 'Light'}Colors.ets`)
    const background = styleExists ? styleRuntime().action(dark) : old.match(/brand: '(#[\w]+)'/)[1]
    const foreground = styleExists ? styleRuntime().onAction(dark) : old.match(/onBrand: '(#[\w]+)'/)[1]
    assert.ok(contrast(background, foreground) >= 4.5, `action contrast ${contrast(background, foreground)}`)
  }
  for (const name of pages) {
    const source = read(`pages/${name}.ets`)
    assert.match(source, /\.backgroundColor\([\s\S]{0,100}?UiStyle\.action\(this\.darkMode\)/)
    assert.match(source, /\.fontColor\([\s\S]{0,100}?UiStyle\.onAction\(this\.darkMode\)/)
    assert.doesNotMatch(source, /Color\.White/)
  }
})

test('import leads with PDF and keeps JSON format and mutually exclusive handlers', () => {
  const pageSource = read('pages/ImportBankPage.ets')
  const source = pageSource.split('  build()')[1]
  assert.ok(source.indexOf("'导入 PDF'") < source.indexOf("'JSON 格式说明'"), 'PDF entry must precede technical JSON instructions')
  assert.match(source, /\.align\(Alignment\.Top\)/)
  assert.match(source, /this\.selectPdf\(\)/)
  assert.match(source, /this\.startImport\(\)/)
  assert.match(source, /\.enabled\(!this\.pdfSelecting && !this\.importing\)/)
  assert.match(source, /\.enabled\(!this\.importing && !this\.pdfSelecting\)/)
  for (const token of ['bankName', 'subject', 'questions', 'single_choice', 'UTF-8']) assert.ok(source.includes(token))

  const exampleMatch = pageSource.match(/const JSON_BANK_EXAMPLE: string = `([\s\S]*?)`/)
  assert.ok(exampleMatch, 'page must provide a complete JSON example')
  const example = JSON.parse(exampleMatch[1])
  assert.equal(example.bankName, '数学错题示例')
  assert.equal(example.subject, '数学')
  assert.equal(example.questions.length, 1)
  assert.deepEqual(Object.keys(example.questions[0]),
    ['id', 'type', 'question', 'options', 'answer', 'analysis'])
  assert.equal(example.questions[0].type, 'single_choice')
  assert.ok(example.questions[0].options.includes('B. 5'))
  assert.equal(example.questions[0].answer, 'B')
  assert.match(source, /Text\('JSON 示例'\)/)
  assert.match(source, /Text\(JSON_BANK_EXAMPLE\)/)
})

test('JSON format guidance is collapsed by default behind one accessible disclosure', () => {
  const pageSource = read('pages/ImportBankPage.ets')
  const source = pageSource.split('  build()')[1]

  assert.match(pageSource, /@State jsonHelpExpanded: boolean = false/)
  assert.match(source, /Text\('JSON 格式与示例'\)/)
  assert.match(source, /Text\(this\.jsonHelpExpanded \? '收起' : '展开'\)/)
  assert.match(source,
    /accessibilityText\(this\.jsonHelpExpanded \?[\s\S]*?'收起 JSON 格式与示例' : '展开 JSON 格式与示例'\)/)
  assert.match(source, /constraintSize\(\{ minHeight: UiStyle\.TOUCH_TARGET \}\)/)
  assert.match(source, /this\.jsonHelpExpanded = !this\.jsonHelpExpanded/)
  assert.match(source,
    /if \(this\.jsonHelpExpanded\) \{[\s\S]*Text\('JSON 格式说明'\)[\s\S]*Text\('JSON 示例'\)[\s\S]*Text\(JSON_BANK_EXAMPLE\)/)
})

test('settings group Model with service and expose status outside the scrolling form', () => {
  const source = read('pages/AiRecognitionSettingsPage.ets')
  const ui = source.slice(source.indexOf('  @Builder'))
  assert.ok(ui.indexOf('text: this.model,') < ui.indexOf('text: this.apiKey,'), 'model must precede credential group')
  assert.ok(ui.indexOf('this.StatusNotice()') < ui.indexOf('Scroll()'), 'operation feedback must stay visible')
  assert.match(ui, /服务与模型/)
  assert.match(ui, /连接验证/)
  assert.match(ui, /密钥管理/)
  assert.match(ui, /InputType\.Password\)\.showPasswordIcon\(false\)/)
  assert.match(ui, /\.enabled\(!this\.pending && this\.apiKey\.length > 0\)/)
  assert.match(ui, /测试连接会发送一张极小测试图片，可能产生极少量模型费用/)
  assert.match(ui, /\.onClick\(\(\) => \{ this\.testConnection\(\) \}\)/)
  assert.match(ui, /\.onClick\(\(\) => this\.leavePage\(\)\)/)
})

test('three page shells consume four insets and constrain readable content and touch targets', () => {
  for (const name of pages) {
    const source = read(`pages/${name}.ets`)
    for (const edge of ['top', 'bottom', 'left', 'right']) {
      assert.ok(source.includes(`SafeAreaUtils.${edge}(this.safeAreaInsets)`), `${name}: missing ${edge} inset`)
    }
    assert.match(source, /maxWidth: UiStyle\.CONTENT_WIDTH/)
    assert.match(source, /minHeight: UiStyle\.TOUCH_TARGET/)
  }
  assert.ok(styleRuntime().TOUCH_TARGET >= 48)
  assert.ok(styleRuntime().CONTENT_WIDTH <= 760)
})

test('picker clears both filters, restores actual catalog and still selects only the platform id', () => {
  const source = read('pages/AiPlatformPickerPage.ets')
  assert.match(source, /清空搜索与筛选/)
  assert.match(source, /private resetFilters\(\): void/)
  assert.match(source, /匹配平台/)
  assert.match(source, /\.accessibilitySelected\(this\.filterKey === item\.key\)/)
  assert.match(source, /\.divider\(/)
  const catalog = read('models/ai/AiPlatformCatalog.ets').replace(/export /g, '')
  const helpers = source.slice(source.indexOf('class CategoryFilter'), source.indexOf('@Entry'))
  const page = (source.slice(source.indexOf('struct AiPlatformPickerPage'), source.indexOf('  build()')) + '}')
    .replace('struct AiPlatformPickerPage', 'class AiPlatformPickerPage')
    .replace(/@StorageProp\([^)]*\)\s*/g, '').replace(/@State\s*/g, '')
  const selected = []
  const r = vm.runInNewContext(stripTypeScriptTypes(catalog + helpers + page, { mode: 'transform' }) +
    '\n({ page: new AiPlatformPickerPage(), AiPlatformCatalog })', {
      AiPlatformSelectionState: { shared: () => ({ select: id => selected.push(id) }) }
    })
  r.page.keyword = 'unmatched-platform-xyz'
  r.page.filterKey = 'local'
  assert.equal(r.page.visiblePlatforms().length, 0)
  r.page.resetFilters()
  assert.equal(r.page.keyword, '')
  assert.equal(r.page.filterKey, 'all')
  assert.equal(r.page.visiblePlatforms().length, r.AiPlatformCatalog.all().length)
  r.page.keyword = 'openai'
  r.page.filterKey = 'local'
  assert.equal(r.page.visiblePlatforms().length, 0)
  r.page.filterKey = 'all'
  assert.ok(r.page.visiblePlatforms().some(p => p.id === 'openai'))
  let back = 0
  r.page.getUIContext = () => ({ getRouter: () => ({ back: () => back++ }) })
  r.page.choose(r.AiPlatformCatalog.find('openai'))
  assert.deepEqual(selected, ['openai'])
  assert.equal(back, 1)
})

test('AI PDF setup presents one responsive configuration flow with persistent feedback and actions', () => {
  const source = read('pages/PdfAiImportSetupPage.ets')
  const ui = source.slice(source.indexOf('  @Builder'))

  for (const label of ['已选择 PDF', '识别服务', '识别平台', '识别模型', '题库信息',
    '识别页码', '调整 AI 设置', '开始后将进入识别进度']) assert.ok(ui.includes(label), label)
  for (const oldLabel of ['AI 视觉识别（推荐）', 'Provider', 'Model', '本机直连']) {
    assert.ok(!ui.includes(oldLabel), `legacy label remains: ${oldLabel}`)
  }

  assert.match(source, /WindowSizeObserver/)
  assert.match(source, /ResponsiveLayout\.classify\(windowWidthVp\)/)
  assert.match(source, /onPageHide\(\): void \{\s*this\.stopWindowObserver\(\)/)
  assert.match(source, /private pageRangeSummary\(\): string/)
  assert.match(ui, /if \(this\.windowSizeClass === WindowSizeClass\.EXPANDED\)/)
  assert.match(ui, /\.align\(Alignment\.Top\)/)
  assert.match(ui, /Text\(this\.providerLabel\)[\s\S]{0,220}?\.maxLines\(2\)/)
  assert.match(ui, /Text\(this\.modelLabel\)[\s\S]{0,220}?\.maxLines\(2\)/)
  assert.match(ui, /\.constraintSize\(\{ minHeight: UiStyle\.TOUCH_TARGET \}\)/)
  assert.match(ui, /\.backgroundColor\(UiStyle\.action\(this\.darkMode\)\)/)
  assert.match(ui, /\.fontColor\(UiStyle\.onAction\(this\.darkMode\)\)/)
  for (const edge of ['top', 'bottom', 'left', 'right']) {
    assert.ok(ui.includes(`SafeAreaUtils.${edge}(this.safeAreaInsets)`), `missing ${edge} inset`)
  }

  const build = source.slice(source.indexOf('  build()'))
  const contentIndex = build.indexOf('this.ContentArea()')
  const statusIndex = build.indexOf('this.StatusNotice()')
  const actionIndex = build.indexOf('this.BottomAction()')
  assert.ok(contentIndex >= 0 && statusIndex > contentIndex && actionIndex > statusIndex,
    'feedback and primary action must remain outside the scrolling content')
  assert.match(source, /\.enabled\(!this\.pending && !this\.leaving\)/)
})

test('AI PDF progress presents a focused responsive stage with persistent recovery actions', () => {
  const source = read('pages/PdfAiImportProgressPage.ets')
  const ui = source.slice(source.indexOf('  @Builder'))

  for (const label of ['识别进度', '当前处理', '已完成页数', '已识别题目',
    '识别按页串行进行']) assert.ok(ui.includes(label), label)
  assert.ok(!ui.includes('AI 视觉识别（推荐）'))
  assert.match(source, /WindowSizeObserver/)
  assert.match(source, /ResponsiveLayout\.classify\(windowWidthVp\)/)
  assert.match(source, /onPageHide\(\): void \{\s*this\.stopWindowObserver\(\)/)
  assert.match(ui, /private ContentArea\(\): void/)
  assert.match(ui, /private StatusNotice\(horizontalPadding: number\): void/)
  assert.match(ui, /private ProgressActions\(horizontalPadding: number\): void/)
  assert.match(ui, /\.align\(Alignment\.Top\)/)
  assert.match(ui, /\.constraintSize\(\{ minHeight: UiStyle\.TOUCH_TARGET \}\)/)
  assert.match(ui, /\.backgroundColor\(UiStyle\.action\(this\.darkMode\)\)/)
  assert.match(ui, /\.fontColor\(UiStyle\.onAction\(this\.darkMode\)\)/)
  for (const edge of ['top', 'bottom', 'left', 'right']) {
    assert.ok(ui.includes(`SafeAreaUtils.${edge}(this.safeAreaInsets)`), `missing ${edge} inset`)
  }

  const build = source.slice(source.indexOf('  build()'))
  const contentIndex = build.indexOf('this.ContentArea()')
  const statusIndex = build.indexOf('this.StatusNotice(PAGE_PADDING)')
  const actionIndex = build.indexOf('this.ProgressActions(PAGE_PADDING)')
  assert.ok(contentIndex >= 0 && statusIndex > contentIndex && actionIndex > statusIndex,
    'feedback and progress actions must remain outside the scrolling content')
})

test('short AI PDF setup content starts at the top of the available pane', () => {
  const source = read('pages/PdfAiImportSetupPage.ets')
  const start = source.indexOf('  private ContentArea(): void')
  const end = source.indexOf('  @Builder', start + 1)
  const content = source.slice(start, end)

  assert.match(content, /List\(\)/, 'setup: use a top-origin scrolling list')
  assert.match(content, /ListItem\(\)/, 'setup: content must be a list item')
  assert.doesNotMatch(content, /Scroll\(\)/,
    'setup: an intrinsic-height Scroll child is centered on the tablet viewport')
})

test('AI PDF progress keeps the tablet task and recovery actions in one focused workspace', () => {
  const source = read('pages/PdfAiImportProgressPage.ets')
  const start = source.indexOf('  private ExpandedStage(): void')
  const end = source.indexOf('  @Builder', start + 1)
  const stage = source.slice(start, end)
  const build = source.slice(source.indexOf('  build()'))

  assert.ok(start >= 0, 'progress: add a dedicated expanded task stage')
  assert.ok(stage.indexOf('this.ProgressOverview()') < stage.indexOf('this.ProgressActions(0)'),
    'progress: keep the action visually attached to the task')
  assert.match(stage, /this\.StatusNotice\(0\)/)
  assert.match(stage, /\.justifyContent\(FlexAlign\.Center\)/)
  assert.match(stage, /\.constraintSize\(\{ maxWidth: this\.contentMaxWidth\(\) \}\)/)
  assert.match(source, /private progressActionMaxWidth\(\): number/)
  assert.match(source, /\.constraintSize\(\{ maxWidth: this\.progressActionMaxWidth\(\) \}\)/)
  assert.match(build,
    /if \(this\.windowSizeClass === WindowSizeClass\.EXPANDED\) \{\s*this\.ExpandedStage\(\)/)
})

test('AI PDF progress applies safe areas to the navigation shell so its title clears the status bar', () => {
  const source = read('pages/PdfAiImportProgressPage.ets')
  const build = source.slice(source.indexOf('  build()'))
  const navigationBodyEnd = build.indexOf("    .title('AI PDF 识别'")
  const navigationBody = build.slice(0, navigationBodyEnd)

  assert.doesNotMatch(navigationBody, /SafeAreaUtils\./,
    'progress: content padding cannot move the native navigation title')
  assert.match(build,
    /\.mode\(NavigationMode\.Stack\)[\s\S]*?\.height\('100%'\)[\s\S]*?\.padding\(\{[\s\S]*?top: SafeAreaUtils\.top\(this\.safeAreaInsets\)[\s\S]*?bottom: SafeAreaUtils\.bottom\(this\.safeAreaInsets\)[\s\S]*?left: SafeAreaUtils\.left\(this\.safeAreaInsets\)[\s\S]*?right: SafeAreaUtils\.right\(this\.safeAreaInsets\)/,
    'progress: the Navigation shell must own all four safe-area insets')
})

test('PDF review uses native navigation and responsive evidence editing with one recovery path', () => {
  const source = read('pages/PdfImportReviewPage.ets')
  const ui = source.slice(source.indexOf('  @Builder'))

  assert.match(source, /WindowSizeObserver/)
  assert.match(source, /ResponsiveLayout\.classify\(windowWidthVp\)/)
  assert.match(source, /onPageHide\(\): void \{\s*this\.stopWindowObserver\(\)/)
  assert.match(ui, /private ReviewContent\(\): void/)
  assert.match(ui, /private StatusNotices\(\): void/)
  assert.match(ui, /private BottomAction\(\): void/)
  assert.match(ui, /if \(this\.windowSizeClass === WindowSizeClass\.EXPANDED &&[\s\S]{0,180}?images\.length > 0\)/)
  assert.match(ui, /\.constraintSize\(\{ minHeight: UiStyle\.TOUCH_TARGET \}\)/)
  assert.match(ui, /\.backgroundColor\(UiStyle\.action\(this\.darkMode\)\)/)
  assert.match(ui, /\.fontColor\(UiStyle\.onAction\(this\.darkMode\)\)/)
  assert.match(ui, /if \(this\.authoritativeStatePending\) \{[\s\S]*?this\.RecoveryState\(\)[\s\S]*?\} else if/)
  assert.equal((ui.match(/Button\('重新加载审核状态'\)/g) || []).length, 1)
  assert.doesNotMatch(ui, /Button\('返回'\)/)
  assert.match(source, /\.hideBackButton\(false\)/)
  for (const edge of ['top', 'bottom', 'left', 'right']) {
    assert.ok(ui.includes(`SafeAreaUtils.${edge}(this.safeAreaInsets)`), `missing ${edge} inset`)
  }

  const build = source.slice(source.indexOf('  build()'))
  const contentIndex = build.indexOf('this.ReviewContent()')
  const statusIndex = build.indexOf('this.StatusNotices()')
  const actionIndex = build.indexOf('this.BottomAction()')
  assert.ok(contentIndex >= 0 && statusIndex > contentIndex && actionIndex > statusIndex,
    'review notices and save action must remain outside the question list')
})

test('PDF review applies safe areas to the navigation shell so its title clears the status bar', () => {
  const source = read('pages/PdfImportReviewPage.ets')
  const build = source.slice(source.indexOf('  build()'))
  const navigationBodyEnd = build.indexOf("    .title('题目识别复核'")
  const navigationBody = build.slice(0, navigationBodyEnd)

  assert.doesNotMatch(navigationBody, /SafeAreaUtils\./,
    'review: content padding cannot move the native navigation title')
  assert.match(build,
    /\.mode\(NavigationMode\.Stack\)[\s\S]*?\.width\('100%'\)[\s\S]*?\.height\('100%'\)[\s\S]*?\.padding\(\{[\s\S]*?top: SafeAreaUtils\.top\(this\.safeAreaInsets\)[\s\S]*?bottom: SafeAreaUtils\.bottom\(this\.safeAreaInsets\)[\s\S]*?left: SafeAreaUtils\.left\(this\.safeAreaInsets\)[\s\S]*?right: SafeAreaUtils\.right\(this\.safeAreaInsets\)/,
    'review: the Navigation shell must own all four safe-area insets')
})

test('PDF review keeps failed pages compact and separates them from recognized questions', () => {
  const source = read('pages/PdfImportReviewPage.ets')
  const failureStart = source.indexOf('  private FailureCard(failure: PdfReviewFailure): void')
  const failureEnd = source.indexOf('  @Builder', failureStart + 1)
  const failureCard = source.slice(failureStart, failureEnd)
  const reviewStart = source.indexOf('  private ReviewContent(): void')
  const reviewEnd = source.indexOf('  @Builder', reviewStart + 1)
  const reviewContent = source.slice(reviewStart, reviewEnd)

  assert.ok(failureStart >= 0, 'review: keep failure handling in a dedicated builder')
  assert.match(failureCard,
    /if \(this\.windowSizeClass === WindowSizeClass\.EXPANDED && failure\.evidencePath\.length > 0\) \{\s*Row\(\{ space: 18 \}\)/,
    'review: expanded failures should put the page thumbnail beside the actions')
  assert.match(failureCard, /\.width\(240\)[\s\S]*?\.height\(200\)/,
    'review: expanded failure evidence should be a bounded thumbnail')
  assert.doesNotMatch(failureCard, /\.height\(this\.windowSizeClass === WindowSizeClass\.EXPANDED \? 300 : 220\)/,
    'review: failed evidence must not reserve a full-width 300vp stage')
  assert.match(reviewContent, /this\.ReviewSectionHeader\('待处理页'/)
  assert.match(reviewContent, /this\.ReviewSectionHeader\('已识别题目'/)
})
