const fs = require('fs')
const path = require('path')

const projectRoot = path.resolve(__dirname, '../../..')
const entryRoot = path.resolve(__dirname, '../main')

function readProject(relativePath) {
  const file = path.join(projectRoot, relativePath)
  if (!fs.existsSync(file)) {
    throw new Error(relativePath + ' is required')
  }
  return fs.readFileSync(file, 'utf8')
}

function readEts(relativePath) {
  const file = path.join(entryRoot, relativePath)
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

const easyGoPath = path.join(projectRoot, 'entry/src/main/resources/base/profile/easy_go.json')
if (!fs.existsSync(easyGoPath)) {
  throw new Error('easy_go.json is required under entry/src/main/resources/base/profile')
}
const easyGo = JSON.parse(fs.readFileSync(easyGoPath, 'utf8'))
if (easyGo.common === undefined || easyGo.common.displayModeOptions === undefined) {
  throw new Error('easy_go.json must define common.displayModeOptions')
}
const display = easyGo.common.displayModeOptions

if (display.wideWindowMode !== 'routerSplit') {
  throw new Error(
    'wideWindowMode must use API24 routerSplit for wide tablet windows'
  )
}
if (display.squareWindowMode !== 'routerSplit') {
  throw new Error('squareWindowMode must enable system routerSplit for square windows')
}
expectAbsent(JSON.stringify(easyGo), 'navigationSplit', 'navigationSplit must not be configured for this Router app')

const split = display.routerSplitOptions
if (split === undefined) {
  throw new Error('routerSplitOptions is required when a mode is routerSplit')
}
if (split.homePage !== 'pages/Index') {
  throw new Error('homePage must be the Router url of the main page: pages/Index')
}
if (split.enableReducedContainerSize !== true) {
  throw new Error('enableReducedContainerSize must be true so panes report their real container size')
}
const fullScreen = split.fullScreenPages
if (!Array.isArray(fullScreen) || fullScreen.length === 0) {
  throw new Error('fullScreenPages must be a non-empty array')
}
const expectedFullScreen = [
  'pages/ImportBankPage',
  'pages/PdfImportSetupPage',
  'pages/PdfImportProgressPage',
  'pages/PdfImportReviewPage',
  'pages/EditQuestionPage'
]
for (const page of expectedFullScreen) {
  if (!fullScreen.includes(page)) {
    throw new Error('fullScreenPages must include focused flow page: ' + page)
  }
}
for (const page of fullScreen) {
  if (page === split.homePage || page === split.relatedPage) {
    throw new Error('fullScreenPages must not contain homePage or relatedPage: ' + page)
  }
}
if (fullScreen.includes('pages/QuestionListPage') || fullScreen.includes('pages/QuestionDetailPage')) {
  throw new Error('QuestionListPage/QuestionDetailPage must stay splittable core content pages')
}
if (split.relatedPage !== undefined && typeof split.relatedPage !== 'string') {
  throw new Error('relatedPage must be a Router url string when configured')
}
const serializedSplit = JSON.stringify(split)

const api26OnlyFields = [
  '"mode"',
  '"wideSplit"',
  '"squareSplit"',
  '"pagePairs"',
  '"transPages"',
  '"splitDividerColor"',
  '"drawableRectHook"',
  '"enableInSplitScreen"',
  '"isDraggable"'
]

for (const field of api26OnlyFields) {
  if (serializedSplit.includes(field)) {
    throw new Error(
      'API24 easy_go config must not contain API26-only field: ' + field
    )
  }
}

const moduleJson = readProject('entry/src/main/module.json5')
expectIncludes(moduleJson, '"easyGo": "$profile:easy_go"', 'module.json5 must reference the easy_go profile')
expectIncludes(moduleJson, '"supportWindowMode": ["fullscreen", "split", "floating"]',
  'free window support must remain configured')

const mainPages = JSON.parse(readProject('entry/src/main/resources/base/profile/main_pages.json'))
const referencedPages = [split.homePage]
if (split.relatedPage !== undefined) {
  referencedPages.push(split.relatedPage)
}
referencedPages.push(...fullScreen)
for (const page of referencedPages) {
  if (!mainPages.src.includes(page)) {
    throw new Error('easy_go referenced page must exist in main_pages.json: ' + page)
  }
}

const books = readEts('ets/pages/BooksPage.ets')
expectAbsent(books, 'WindowLayoutPolicy', 'books page must not use the removed hand-written ratio policy')
expectAbsent(books, 'selectedBankId', 'books page must not keep fake dual-pane selection state')
expectAbsent(books, 'selectBankForPane', 'books page must not simulate the system split pane')
expectAbsent(books, 'useSplitPane', 'books page must not decide panes by itself')
expectAbsent(books, 'onAreaChange', 'books page must rely on the container, not the whole screen')
expectAbsent(books, 'windowWidth >= 600', 'books page must not switch on a fixed pixel width')
expectIncludes(books, "url: 'pages/QuestionListPage'", 'phone flow must keep router navigation')
expectIncludes(books, 'CloudQuestionRepository.listCachedBanks', 'books page must keep loading from the cloud cache')
expectIncludes(books, 'CONTENT_MAX_WIDTH', 'books page must cap content width for wide containers')

const list = readEts('ets/pages/QuestionListPage.ets')
expectAbsent(list, 'WindowLayoutPolicy', 'question list must not use the removed hand-written ratio policy')
expectAbsent(list, 'previewQuestionId', 'question list must not keep fake dual-pane preview state')
expectAbsent(list, 'QuestionPreviewPane', 'question list must not simulate the system split pane')
expectAbsent(list, 'useSplitPane', 'question list must not decide panes by itself')
expectAbsent(list, 'onAreaChange', 'question list must rely on the container, not the whole screen')
expectIncludes(list, "url: 'pages/QuestionDetailPage'", 'phone flow must keep router navigation')
expectIncludes(list, 'CloudQuestionRepository.listCachedQuestions',
  'question list must keep loading from the cloud cache')
expectIncludes(list, 'CONTENT_MAX_WIDTH', 'question list must cap content width for wide containers')
expectIncludes(list, 'isEasySplit()', 'question list must expose the guarded runtime split check')
expectIncludes(list, 'try {', 'runtime split check must be guarded')

const detail = readEts('ets/pages/QuestionDetailPage.ets')
expectAbsent(detail, 'WindowLayoutPolicy', 'detail page must not use the removed hand-written ratio policy')
expectIncludes(detail, 'isEasySplit()', 'detail page must expose the guarded runtime split check')

const indexPage = readEts('ets/pages/Index.ets')
expectIncludes(indexPage, 'HdsTabs({ barPosition: BarPosition.End, index: this.selectedIndex })',
  'the HDS Tabs must own the bottom bar')
expectAbsent(indexPage, 'SafeAreaUtils.bottom', 'the native TabBar must handle the bottom safe area itself')
expectAbsent(indexPage, '.height(60)', 'the native TabBar must not hard-code a fixed item height')

const pageFiles = fs.readdirSync(path.join(entryRoot, 'ets/pages')).filter((name) => name.endsWith('.ets'))
for (const name of pageFiles) {
  const source = readEts('ets/pages/' + name)
  expectAbsent(source, 'WindowLayoutPolicy', name + ' must not reference the removed ratio policy')
  expectAbsent(source, 'aspectRatio', name + ' must not compute its own window ratio')
  expectAbsent(source, 'deviceType', name + ' must not branch on device type')
  expectAbsent(source, 'isTablet', name + ' must not branch on tablet flags')
}

process.stdout.write('EasyGo parallel view contracts passed\n')
