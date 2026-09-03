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

function themeFilesExist() {
  for (const name of ['AppColors.ets', 'LightColors.ets', 'DarkColors.ets', 'ThemeManager.ets']) {
    const file = path.join(etsRoot, 'theme', name)
    if (!fs.existsSync(file)) {
      throw new Error('theme/' + name + ' is required')
    }
  }
}
themeFilesExist()

const appColors = readEts('ets/theme/AppColors.ets')
for (const field of ['pageBackground', 'cardBackground', 'textPrimary', 'textSecondary', 'divider',
  'brand', 'success', 'warning', 'error']) {
  expectIncludes(appColors, field + ': string', 'AppColors must centralize the ' + field + ' color')
}

const lightColors = readEts('ets/theme/LightColors.ets')
const darkColors = readEts('ets/theme/DarkColors.ets')
expectIncludes(lightColors, 'static readonly INSTANCE: AppColors', 'light palette instance is required')
expectIncludes(darkColors, 'static readonly INSTANCE: AppColors', 'dark palette instance is required')
expectIncludes(lightColors, "pageBackground: '#F5F7FB'", 'light page background must stay the app background')
expectAbsent(darkColors, "pageBackground: '#F5F7FB'", 'dark page background must differ from the light one')
expectAbsent(darkColors, 'invert', 'dark palette must not rely on color inversion')

const themeManager = readEts('ets/theme/ThemeManager.ets')
expectIncludes(themeManager, 'enum ThemeMode', 'ThemeMode must offer light/dark/system choices')
expectIncludes(themeManager, 'setOrCreate', 'ThemeManager must publish the effective mode through AppStorage')
expectIncludes(themeManager, "'darkMode'", 'ThemeManager must drive the shared darkMode key')
expectIncludes(themeManager, 'setColorMode',
  'ThemeManager must sync the app color mode so the status bar and system glass follow theme switches')
expectIncludes(themeManager, 'COLOR_MODE_NOT_SET', 'follow-system mode must restore the system color mode')

const hardcodedColor = /'#[0-9A-Fa-f]{6,8}'/
const pageDir = path.join(etsRoot, 'pages')
const componentDir = path.join(etsRoot, 'components')
for (const dir of [pageDir, componentDir]) {
  const files = []
  listFiles(dir, (name) => name.endsWith('.ets'), files)
  for (const file of files) {
    const relative = path.relative(etsRoot, file).split(path.sep).join('/')
    const source = fs.readFileSync(file, 'utf8')
    expectAbsent(source, 'COLOR_', relative + ' must not import legacy fixed color constants')
    if (hardcodedColor.test(source)) {
      throw new Error(relative + ' must not hardcode a fixed theme color: ' +
        source.match(hardcodedColor)[0])
    }
  }
}

const policyPath = path.join(etsRoot, 'constants', 'HdsMaterialPolicy.ets')
if (!fs.existsSync(policyPath)) {
  throw new Error('HdsMaterialPolicy.ets is required under entry/src/main/ets/constants')
}
const policy = fs.readFileSync(policyPath, 'utf8')
expectIncludes(policy, 'hdsMaterial.MaterialType.ADAPTIVE', 'the official material policy must resolve ADAPTIVE')
expectIncludes(policy, 'hdsMaterial.MaterialLevel.ADAPTIVE', 'the official material policy must resolve the ADAPTIVE level')
expectAbsent(policy, 'Dark', 'the material policy must not keep manual dark variants')
expectAbsent(policy, 'materialColor:', 'the material policy must let the system compute light/dark colors')
const indexPage = readEts('ets/pages/Index.ets')
expectIncludes(indexPage, 'systemMaterialEffect:',
  'the HdsTabs bar must keep the official system material in every color mode')
const hdsSurface = indexPage.slice(indexPage.indexOf('HdsTabs({'), indexPage.indexOf('.onChange('))
expectAbsent(hdsSurface, "'#FFFFFF'", 'the HDS tab bar must not hardcode a light background')
expectAbsent(hdsSurface, "'#000000'", 'the HDS tab bar must not hardcode a dark background')
expectAbsent(hdsSurface, 'backgroundColor', 'the HDS tab bar must not stack a solid background')

const appTheme = readEts('ets/constants/AppTheme.ets')
expectIncludes(appTheme, 'TAB_BAR_CLEARANCE: number', 'the native tab bar clearance must be a shared layout constant')
expectIncludes(appTheme, 'CONTENT_MAX_WIDTH: number = 760', 'wide screens must stay capped by CONTENT_MAX_WIDTH')

for (const relative of ['ets/pages/HomePage.ets', 'ets/pages/BooksPage.ets', 'ets/pages/WrongQuestionsPage.ets',
  'ets/pages/MinePage.ets']) {
  const source = readEts(relative)
  expectAbsent(source, 'AppHeader', relative + ' must not mount a simulated header')
  expectAbsent(source, 'headerClearance', relative + ' must let the Navigation title bar own its layout')
  expectAbsent(source, 'Stack({ alignContent: Alignment.Top })',
    relative + ' must not layer a hand-made floating header')
}

for (const relative of ['ets/pages/HomePage.ets', 'ets/pages/BooksPage.ets', 'ets/pages/WrongQuestionsPage.ets']) {
  const source = readEts(relative)
  expectIncludes(source, '.contentEndOffset(TAB_BAR_CLEARANCE)',
    relative + ' must let the last item scroll above the native floating TabBar')
}

const minePage = readEts('ets/pages/MinePage.ets')
expectIncludes(minePage, 'ThemeManager.setMode', 'mine page must expose the theme mode switch')
expectIncludes(minePage, 'ThemeMode.SYSTEM', 'theme switch must offer follow-system mode')
expectIncludes(minePage, "'深色模式'", 'theme switch row must be labeled')
expectIncludes(minePage, 'bottom: TAB_BAR_CLEARANCE',
  'mine scroll content must end above the native floating TabBar')

for (const relative of ['ets/pages/HomePage.ets', 'ets/pages/WrongQuestionsPage.ets', 'ets/pages/MinePage.ets',
  'ets/pages/QuestionDetailPage.ets', 'ets/pages/Index.ets']) {
  expectIncludes(readEts(relative), "@StorageProp('darkMode')",
    relative + ' must bind the shared darkMode state')
}

const entryAbility = readEts('ets/entryability/EntryAbility.ets')
expectIncludes(entryAbility, 'setWindowLayoutFullScreen(true)',
  'immersive fullscreen window layout must stay intact')
expectIncludes(entryAbility, 'ThemeManager.initialize', 'ability must initialize the theme layer')
expectIncludes(entryAbility, 'onConfigurationUpdate', 'ability must react to system color mode changes')
expectIncludes(entryAbility, 'colors.statusBarIcon', 'status bar icons must follow the active theme')
expectIncludes(entryAbility, 'setWindowSystemBarProperties',
  'status and navigation bar icon colors must be set for the active theme')

const baseColors = JSON.parse(readProject('entry/src/main/resources/base/element/color.json'))
const darkResourceColors = JSON.parse(readProject('entry/src/main/resources/dark/element/color.json'))
for (const file of [baseColors, darkResourceColors]) {
  if (!Array.isArray(file.color) || file.color.length < 5) {
    throw new Error('resource color.json must provide the theme color set')
  }
}
const baseNames = baseColors.color.map((item) => item.name)
const darkNames = darkResourceColors.color.map((item) => item.name)
for (const name of ['page_background', 'card_background', 'text_primary', 'divider', 'brand']) {
  if (!baseNames.includes(name) || !darkNames.includes(name)) {
    throw new Error('resource color.json must define ' + name + ' in both light and dark')
  }
}

const easyGoPath = path.join(entryMain, 'resources/base/profile/easy_go.json')
if (!fs.existsSync(easyGoPath)) {
  throw new Error('easy_go.json is required')
}
const easyGo = JSON.parse(fs.readFileSync(easyGoPath, 'utf8'))
if (easyGo.common === undefined || easyGo.common.displayModeOptions === undefined ||
  easyGo.common.displayModeOptions.routerSplitOptions === undefined) {
  throw new Error('easy_go routerSplit config must stay untouched')
}
expectIncludes(readProject('entry/src/main/module.json5'), '"easyGo": "$profile:easy_go"',
  'easy_go reference must remain in module.json5')

const safeAreaPath = path.join(etsRoot, 'utils', 'SafeAreaUtils.ets')
if (!fs.existsSync(safeAreaPath)) {
  throw new Error('SafeAreaUtils.ets is required')
}
const safeArea = fs.readFileSync(safeAreaPath, 'utf8')
expectIncludes(safeArea, 'static top(', 'SafeAreaUtils.top must stay intact')
expectIncludes(safeArea, 'static bottom(', 'SafeAreaUtils.bottom must stay intact')

const serverRoot = path.join(projectRoot, 'server')
if (!fs.existsSync(serverRoot)) {
  throw new Error('server/ is required')
}
const serverFiles = []
listFiles(serverRoot, (name) => /\.(ts|js|json|json5|ets)$/.test(name), serverFiles)
for (const file of serverFiles) {
  const source = fs.readFileSync(file, 'utf8')
  const relative = path.relative(projectRoot, file)
  for (const token of ['ThemeManager', 'AppColors', 'darkMode', 'HdsMaterialPolicy', 'themePalette']) {
    expectAbsent(source, token, relative + ' must stay untouched by the dark mode work')
  }
}

process.stdout.write('Dark mode contracts passed\n')
