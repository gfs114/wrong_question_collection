const fs = require('fs')
const path = require('path')

const projectRoot = path.resolve(__dirname, '../../..')
const entryMain = path.resolve(__dirname, '../main')
const etsRoot = path.join(entryMain, 'ets')

function readFile(relativePath) {
  const file = path.join(projectRoot, relativePath)
  if (!fs.existsSync(file)) {
    throw new Error(relativePath + ' is required')
  }
  return fs.readFileSync(file, 'utf8')
}

function readEts(relativePath) {
  return readFile(path.join('entry/src/main', relativePath).replace(/\\/g, '/'))
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

function materialBlock(source, name) {
  const marker = 'static readonly ' + name + ':'
  const start = source.indexOf(marker)
  if (start < 0) {
    throw new Error('ImmersiveMaterials.' + name + ' is required')
  }
  const end = source.indexOf('static readonly', start + marker.length)
  return source.slice(start, end < 0 ? source.length : end)
}

function sliceBetween(source, fromText, toText, message) {
  const start = source.indexOf(fromText)
  const end = source.indexOf(toText)
  if (start < 0 || end < 0 || end < start) {
    throw new Error(message)
  }
  return source.slice(start, end)
}

const materialsPath = path.join(etsRoot, 'constants', 'ImmersiveMaterials.ets')
if (!fs.existsSync(materialsPath)) {
  throw new Error('ImmersiveMaterials.ets is required under entry/src/main/ets/constants')
}
const materials = fs.readFileSync(materialsPath, 'utf8')

expectIncludes(materials, "import uiMaterial from '@ohos.arkui.uiMaterial'",
  'the official ArkUI material module must be imported')
expectIncludes(materials, 'new uiMaterial.ImmersiveMaterial',
  'materials must use the official uiMaterial.ImmersiveMaterial class')

const navigationBlock = materialBlock(materials, 'navigation')
const headerBlock = materialBlock(materials, 'header')
const overviewBlock = materialBlock(materials, 'overviewCard')
const accountBlock = materialBlock(materials, 'accountCard')
const floatingBlock = materialBlock(materials, 'floatingButton')
const selectedBlock = materialBlock(materials, 'selectedControl')

expectIncludes(navigationBlock, 'ImmersiveStyle.REGULAR',
  'navigation must use a medium REGULAR material')
expectIncludes(headerBlock, 'ImmersiveStyle.ULTRA_THIN',
  'header must use a lighter material than the navigation bar')
expectIncludes(overviewBlock, 'ImmersiveStyle.THIN',
  'overview card must use a light material')
expectIncludes(navigationBlock, 'interactive: true', 'navigation material must be interactive')
expectIncludes(headerBlock, 'interactive: false', 'header material must be non-interactive')
expectIncludes(overviewBlock, 'interactive: false', 'overview card material must be non-interactive')
expectIncludes(accountBlock, 'interactive: true', 'account card material must be interactive')
expectIncludes(floatingBlock, 'interactive: true', 'floating back button must react to touch')
expectIncludes(selectedBlock, 'interactive: true', 'selected control must react to touch')
expectAbsent(headerBlock, 'interactive: true', 'header material must not claim interactivity')
expectAbsent(overviewBlock, 'interactive: true', 'overview material must not claim interactivity')

for (const name of ['navigation', 'header', 'floatingButton', 'selectedControl', 'overviewCard', 'accountCard']) {
  const block = materialBlock(materials, name)
  expectAbsent(block, 'backgroundBlurStyle', name + ' must not fake blur outside the official API')
}

const navigation = readEts('ets/components/MainBottomNavigation.ets')
expectIncludes(navigation, '.systemMaterial(ImmersiveMaterials.navigationFor(this.darkMode))',
  'bottom navigation must use the official systemMaterial API')
expectIncludes(navigation, '.borderRadius(38)', 'bottom navigation must keep its floating corner radius')
expectIncludes(navigation, 'SafeAreaUtils.bottom(this.safeAreaInsets)',
  'bottom navigation must keep the live bottom safe-area inset')
expectIncludes(navigation, 'selectedIndex', 'bottom navigation must keep the selectedIndex logic')
expectIncludes(navigation, 'onSelect', 'bottom navigation must keep the tab click callback')
const navSurface = sliceBetween(navigation, ".width('92%')", '.systemMaterial(ImmersiveMaterials.navigationFor',
  'bottom navigation surface modifiers are missing')
expectAbsent(navSurface, 'backgroundColor',
  'bottom navigation material must be the background, not a stacked solid color')
expectAbsent(navSurface, 'backgroundBlurStyle', 'bottom navigation must not stack homemade blur')
expectAbsent(navSurface, '.shadow(', 'bottom navigation must not stack a hand-made shadow')

const header = readEts('ets/components/AppHeader.ets')
expectIncludes(header, '.systemMaterial(ImmersiveMaterials.headerFor(this.darkMode))',
  'app header container must use the official systemMaterial API')
expectIncludes(header, '.systemMaterial(ImmersiveMaterials.floatingButtonFor(this.darkMode))',
  'back button must use the official floating button material')
expectIncludes(header, 'SafeAreaUtils.top(this.safeAreaInsets)',
  'app header must keep the live top safe-area inset')
const headerSurface = sliceBetween(header, ".height(76)", '.systemMaterial(ImmersiveMaterials.headerFor',
  'app header surface modifiers are missing')
expectAbsent(headerSurface, 'backgroundColor', 'header material must not stack a solid background')
expectAbsent(headerSurface, 'backgroundBlurStyle', 'header must not stack homemade blur')

const overviewCard = readEts('ets/components/HomeOverviewCard.ets')
expectIncludes(overviewCard, '.systemMaterial(ImmersiveMaterials.overviewCardFor(this.darkMode))',
  'home overview card must use the official overview material')
const overviewSurface = sliceBetween(overviewCard, '.padding(22)', '.systemMaterial(ImmersiveMaterials.overviewCardFor',
  'overview card surface modifiers are missing')
expectAbsent(overviewSurface, 'backgroundColor', 'overview card must not stack a solid background')

const accountCard = readEts('ets/components/HuaweiAccountCard.ets')
expectIncludes(accountCard, '.systemMaterial(ImmersiveMaterials.accountCardFor(this.darkMode))',
  'mine account card must use the official account material')

const nonMaterialComponents = [
  'components/QuestionBankCard.ets',
  'components/QuestionCard.ets',
  'components/WrongQuestionCard.ets',
  'components/StatCard.ets',
  'components/EmptyState.ets',
  'components/SectionTitle.ets',
  'components/HomeRecentSection.ets',
  'components/LegacyMigrationCard.ets',
  'components/CloudImportStatusCard.ets',
  'components/QuestionSourceImages.ets'
]
for (const relative of nonMaterialComponents) {
  const source = readEts('ets/' + relative)
  expectAbsent(source, 'systemMaterial',
    relative + ' is a plain content surface and must not get immersive material')
}

const allowedMaterialUsages = {
  'components/MainBottomNavigation.ets': 1,
  'components/AppHeader.ets': 2,
  'components/HomeOverviewCard.ets': 1,
  'components/HuaweiAccountCard.ets': 1,
  'pages/WrongQuestionsPage.ets': 2
}
for (const file of allEtsFiles()) {
  const source = fs.readFileSync(file, 'utf8')
  const count = source.split('.systemMaterial(').length - 1
  if (count === 0) {
    continue
  }
  const relative = path.relative(etsRoot, file).split(path.sep).join('/')
  if (allowedMaterialUsages[relative] !== count) {
    throw new Error('unexpected systemMaterial usage in ' + relative +
      ': found ' + count + ' occurrence(s), allowed ' + (allowedMaterialUsages[relative] || 0))
  }
  expectAbsent(source, 'new uiMaterial.ImmersiveMaterial',
    relative + ' must not build its own material, use ImmersiveMaterials constants')
}

for (const file of allEtsFiles()) {
  const source = fs.readFileSync(file, 'utf8')
  const relative = path.relative(etsRoot, file).split(path.sep).join('/')
  expectAbsent(source, 'backgroundBlurStyle', relative + ' must not fake immersive blur')
  expectAbsent(source, '.blur(', relative + ' must not fake immersive blur')
}

const forbiddenServices = [
  'services/CloudQuestionRepository.ets',
  'services/CloudCacheService.ets',
  'models/SyncModels.ets',
  'services/CloudSyncService.ets',
  'services/CloudImportService.ets',
  'services/ApiHttpClient.ets',
  'services/AccountSessionService.ets',
  'services/ConnectivityPolicy.ets',
  'services/DeviceImageStore.ets',
  'services/LegacyCloudMigrationService.ets',
  'services/RemoteOperationApplier.ets'
]
for (const relative of forbiddenServices) {
  const source = readEts('ets/' + relative)
  expectAbsent(source, 'uiMaterial', relative + ' must stay untouched by the material work')
  expectAbsent(source, 'systemMaterial', relative + ' must stay untouched by the material work')
}

const serverRoot = path.join(projectRoot, 'server')
if (!fs.existsSync(serverRoot)) {
  throw new Error('server/ is required')
}
const serverFiles = []
listFiles(serverRoot, (name) => /\.(ts|js|json|json5|ets)$/.test(name), serverFiles)
for (const file of serverFiles) {
  if (file.includes(path.sep + 'node_modules' + path.sep) ||
    file.includes(path.sep + 'dist' + path.sep) || file.includes(path.sep + 'build' + path.sep)) {
    continue
  }
  const source = fs.readFileSync(file, 'utf8')
  const relative = path.relative(projectRoot, file)
  expectAbsent(source, 'systemMaterial', relative + ' must not reference immersive material APIs')
  expectAbsent(source, 'ImmersiveMaterial', relative + ' must not reference immersive material APIs')
  expectAbsent(source, 'uiMaterial', relative + ' must not reference immersive material APIs')
}

const easyGoPath = path.join(entryMain, 'resources/base/profile/easy_go.json')
if (!fs.existsSync(easyGoPath)) {
  throw new Error('easy_go.json is required')
}
const easyGo = JSON.parse(fs.readFileSync(easyGoPath, 'utf8'))
if (easyGo.common === undefined || easyGo.common.displayModeOptions === undefined ||
  easyGo.common.displayModeOptions.routerSplitOptions === undefined) {
  throw new Error('easy_go.json must keep routerSplitOptions for parallel view')
}
const moduleJson = readFile('entry/src/main/module.json5')
expectIncludes(moduleJson, '"easyGo": "$profile:easy_go"', 'easy_go reference must remain in module.json5')
expectIncludes(moduleJson, '"ohos.arkui.UIMaterial.state"',
  'the official app-level material switch metadata must remain')
expectIncludes(moduleJson, '"enable"', 'the official material switch must stay enabled')

const safeAreaPath = path.join(etsRoot, 'utils', 'SafeAreaUtils.ets')
if (!fs.existsSync(safeAreaPath)) {
  throw new Error('SafeAreaUtils.ets is required')
}
const safeArea = fs.readFileSync(safeAreaPath, 'utf8')
expectIncludes(safeArea, 'static top(', 'SafeAreaUtils.top must remain')
expectIncludes(safeArea, 'static bottom(', 'SafeAreaUtils.bottom must remain')

process.stdout.write('Immersive light sense contracts passed\n')
