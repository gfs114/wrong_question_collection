const fs = require('fs')
const path = require('path')

const projectRoot = path.resolve(__dirname, '../../..')
const entryMain = path.resolve(__dirname, '../main')
const etsRoot = path.join(entryMain, 'ets')

function readProject(relativePath) {
  const file = path.join(projectRoot, relativePath)
  if (!fs.existsSync(file)) {
    throw new Error(relativePath + ' is required')
  }
  return fs.readFileSync(file, 'utf8')
}

function readEts(relativePath) {
  return readProject(path.join('entry/src/main', relativePath).replace(/\\/g, '/'))
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

function listFiles(dir, predicate, output) {
  let entries
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true })
  } catch (err) {
    return
  }
  for (const entry of entries) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) {
      if (entry.name === 'node_modules' || entry.name === 'dist' || entry.name === 'build' ||
        entry.name === 'coverage' || entry.name === '__pycache__' || entry.name.startsWith('.')) {
        continue
      }
      listFiles(full, predicate, output)
    } else if (predicate(entry.name)) {
      output.push(full)
    }
  }
}

function allEtsFiles() {
  const files = []
  if (fs.existsSync(etsRoot)) {
    listFiles(etsRoot, (name) => name.endsWith('.ets'), files)
  }
  return files
}

// 1. 不存在自定义 MainBottomNavigation
const customNavPath = path.join(etsRoot, 'components', 'MainBottomNavigation.ets')
if (fs.existsSync(customNavPath)) {
  throw new Error('MainBottomNavigation.ets must be deleted, Tabs TabBar must replace it')
}
for (const file of allEtsFiles()) {
  const relative = path.relative(etsRoot, file).split(path.sep).join('/')
  expectAbsent(fs.readFileSync(file, 'utf8'), 'MainBottomNavigation',
    relative + ' must not reference the removed custom bottom navigation')
}

// 2. 不存在 AppHeader 模拟标题栏
const appHeaderPath = path.join(etsRoot, 'components', 'AppHeader.ets')
if (fs.existsSync(appHeaderPath)) {
  throw new Error('AppHeader.ets must be deleted, Navigation.title must replace it')
}
for (const file of allEtsFiles()) {
  const relative = path.relative(etsRoot, file).split(path.sep).join('/')
  const source = fs.readFileSync(file, 'utf8')
  expectAbsent(source, 'AppHeader(', relative + ' must not mount the removed simulated header')
  expectAbsent(source, 'showBack:', relative + ' must not carry simulated header back-button flags')
}

// 3. HdsTabs 存在（HdsTabs + TabContent + 原生 TabBar）
const index = readEts('ets/pages/Index.ets')
expectIncludes(index, 'HdsTabs({ barPosition: BarPosition.End, index: this.selectedIndex })',
  'index must host a HdsTabs with a bottom bar')
for (const token of ['TabContent() {', '.tabBar(', 'barOverlap(true)', 'barFloatingStyle({']) {
  expectIncludes(index, token, 'index HdsTabs must use the official ' + token + ' integration point')
}
expectIncludes(index, "this.TabBarItem(MainTabIndex.HOME, '首页', $r('sys.symbol.house_fill'))",
  'home tab must stay first in the native TabBar')
expectIncludes(index, "this.TabBarItem(MainTabIndex.BOOKS, '题库', $r('sys.symbol.book'))",
  'books tab must stay second in the native TabBar')
expectIncludes(index, "this.TabBarItem(MainTabIndex.WRONG_QUESTIONS, '错题',",
  'wrong-questions tab must stay third in the native TabBar')
expectIncludes(index, "this.TabBarItem(MainTabIndex.MINE, '我的', $r('sys.symbol.person_fill'))",
  'mine tab must stay fourth in the native TabBar')

// 4. Navigation 存在（首页 + 二级页面原生标题栏与返回键）
expectIncludes(index, 'Navigation() {', 'index must host a native Navigation root')
expectIncludes(index, ".title(this.titleFor(this.selectedIndex), {",
  'index must set the title through Navigation.title')
expectIncludes(index, 'toolbarConfiguration(', 'index must use the official Navigation toolbar')
for (const title of ["'首页'", "'题库'", "'错题'", "'我的'"]) {
  expectIncludes(index, title, 'index must rotate the tab title ' + title)
}
const detailPages = {
  'pages/QuestionListPage.ets': 'this.bankName',
  'pages/QuestionDetailPage.ets': "'题目详情'",
  'pages/WrongQuestionDetailPage.ets': "'错题详情'",
  'pages/EditQuestionPage.ets': "'编辑题目'"
}
for (const page of Object.keys(detailPages)) {
  const source = readEts('ets/' + page)
  expectIncludes(source, 'Navigation() {', page + ' must host a native Navigation root')
  expectIncludes(source, '.title(' + detailPages[page], page + ' must title the bar through Navigation.title')
  expectIncludes(source, '.titleMode(NavigationTitleMode.Mini)', page + ' must enable the mini title bar')
  expectIncludes(source, '.hideBackButton(false)', page + ' must use the Navigation back button')
  expectIncludes(source, '.mode(NavigationMode.Stack)', page + ' must force stack mode for router pages')
  expectAbsent(source, 'showBack:', page + ' must not use a simulated back button')
  expectAbsent(source, "Text('‹')", page + ' must not hand-draw a back chevron')
}

// 5. API26 材质接入点全部移除；HDS systemMaterialEffect 只存在于 HdsTabs barFloatingStyle
for (const file of allEtsFiles()) {
  const relative = path.relative(etsRoot, file).split(path.sep).join('/')
  const source = fs.readFileSync(file, 'utf8')
  const universalCalls = source.split('.systemMaterial(').length - 1
  if (universalCalls !== 0) {
    throw new Error(relative + ' must not call the API 26 universal .systemMaterial attribute')
  }
  expectAbsent(source, 'systemMaterial:',
    relative + ' must not configure the API 26 NavigationTitleOptions.systemMaterial field')
  const lines = source.split(/\r?\n/)
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    if (!lines[lineIndex].includes('systemMaterialEffect:')) {
      continue
    }
    const window = lines.slice(Math.max(0, lineIndex - 5), lineIndex + 1).join('\n')
    const nearFloating = window.includes('barFloatingStyle({')
    if (!nearFloating) {
      throw new Error(relative +
        ' must attach systemMaterialEffect only to the HdsTabs barFloatingStyle')
    }
  }
}
expectIncludes(index, 'systemMaterialEffect:',
  'the HdsTabs bar must keep the official HDS immersive material effect')

// 6. easy_go.json 未改变
const easyGoPath = path.join(entryMain, 'resources/base/profile/easy_go.json')
if (!fs.existsSync(easyGoPath)) {
  throw new Error('easy_go.json is required')
}
const easyGo = JSON.parse(fs.readFileSync(easyGoPath, 'utf8'))
if (easyGo.common === undefined || easyGo.common.displayModeOptions === undefined) {
  throw new Error('easy_go.json must keep displayModeOptions untouched')
}
const display = easyGo.common.displayModeOptions
if (display.wideWindowMode !== 'original') {
  throw new Error('easy_go.json wideWindowMode must stay original')
}
if (display.squareWindowMode !== 'routerSplit') {
  throw new Error('easy_go.json squareWindowMode must stay routerSplit')
}
const split = display.routerSplitOptions
if (split === undefined || split.homePage !== 'pages/Index' || split.mode !== 1 ||
  split.enableReducedContainerSize !== true) {
  throw new Error('easy_go.json routerSplitOptions must stay untouched with pages/Index as homePage')
}
const fullScreenPages = split.fullScreenPages || []
for (const page of ['pages/ImportBankPage', 'pages/PdfImportSetupPage', 'pages/PdfImportProgressPage',
  'pages/PdfImportReviewPage', 'pages/EditQuestionPage']) {
  if (!fullScreenPages.includes(page)) {
    throw new Error('easy_go.json fullScreenPages must keep ' + page)
  }
}
const moduleJson = readProject('entry/src/main/module.json5')
expectIncludes(moduleJson, '"easyGo": "$profile:easy_go"', 'module.json5 easy_go reference must remain')

// 7. Router pushUrl 保留（UIContext Router 兼容）
for (const page of ['ets/pages/Index.ets', 'ets/pages/BooksPage.ets', 'ets/pages/WrongQuestionsPage.ets',
  'ets/pages/QuestionListPage.ets', 'ets/pages/QuestionDetailPage.ets', 'ets/pages/ImportBankPage.ets']) {
  const source = readEts(page)
  expectIncludes(source, "this.getUIContext().getRouter().pushUrl(options)",
    page + ' must keep UIContext router.pushUrl navigation')
}
expectIncludes(index, 'router.RouterOptions', 'index must keep typed router options')

// 8. 同步模块零修改
const forbiddenServices = [
  'services/CloudQuestionRepository.ets',
  'services/CloudSyncService.ets',
  'services/CloudCacheService.ets',
  'models/SyncModels.ets',
  'services/CloudImportService.ets',
  'services/AccountSessionService.ets',
  'services/DatabaseService.ets'
]
const navigationTokens = ['Navigation(', 'Tabs(', 'systemMaterial', 'barFloatingStyle',
  'HdsMaterialPolicy', 'HdsTabs', 'NavigationTitleMode']
for (const relative of forbiddenServices) {
  const source = readEts('ets/' + relative)
  for (const token of navigationTokens) {
    expectAbsent(source, token, relative + ' must stay untouched by the native navigation refactor')
  }
}
const serverRoot = path.join(projectRoot, 'server')
if (!fs.existsSync(serverRoot)) {
  throw new Error('server/ is required')
}
const serverFiles = []
listFiles(serverRoot, (name) => /\.(ts|js|json|json5)$/.test(name), serverFiles)
for (const file of serverFiles) {
  if (file.includes(path.sep + 'node_modules' + path.sep) ||
    file.includes(path.sep + 'dist' + path.sep) || file.includes(path.sep + 'build' + path.sep)) {
    continue
  }
  const source = fs.readFileSync(file, 'utf8')
  const relative = path.relative(projectRoot, file)
  for (const token of navigationTokens) {
    expectAbsent(source, token, relative + ' must stay untouched by the native navigation refactor')
  }
}
const workerRoot = path.join(projectRoot, 'worker')
if (fs.existsSync(workerRoot)) {
  const workerFiles = []
  listFiles(workerRoot, (name) => /\.(ts|js|ets|json|json5)$/.test(name), workerFiles)
  for (const file of workerFiles) {
    const source = fs.readFileSync(file, 'utf8')
    const relative = path.relative(projectRoot, file)
    for (const token of navigationTokens) {
      expectAbsent(source, token, relative + ' must stay untouched by the native navigation refactor')
    }
  }
}

process.stdout.write('Native navigation contracts passed\n')
