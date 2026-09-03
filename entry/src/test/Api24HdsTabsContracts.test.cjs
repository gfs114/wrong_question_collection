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

// 1. API26 实验与诊断文件全部删除
for (const relative of ['ets/constants/BottomBarImplementation.ets',
  'ets/constants/ImmersiveMaterials.ets',
  'ets/utils/ImmersiveMaterialDiagnostics.ets',
  'ets/components/MaterialProbeZones.ets']) {
  const file = path.join(entryMain, relative)
  if (fs.existsSync(file)) {
    throw new Error(relative + ' must be deleted from the official API 24 path')
  }
}

// 2. HdsTabs 是唯一正式底栏（无 ArkUI Tabs 分支、无 A/B 开关）
const index = readEts('ets/pages/Index.ets')
expectAbsent(index, 'BottomBarImplementation', 'index must not branch on the removed A/B switch')
expectAbsent(index, 'BOTTOM_BAR_IMPLEMENTATION', 'index must not reference the removed A/B switch constant')
expectAbsent(index, 'ImmersiveMaterials', 'index must not reference the removed API 26 material constants')
expectAbsent(index, 'ImmersiveMaterialDiagnostics', 'index must not reference the removed API 26 diagnostics')
expectIncludes(index, 'HdsTabs({ barPosition: BarPosition.End, index: this.selectedIndex })',
  'index must host HdsTabs as the official bottom navigation with index binding')
const hdsStart = index.indexOf('HdsTabs({')
const hdsEnd = index.indexOf('.onChange(', hdsStart)
if (hdsEnd < 0) {
  throw new Error('the HdsTabs host must keep its onChange handler')
}
const hdsBranch = index.slice(hdsStart, hdsEnd)

// 3. HDS 官方悬浮样式 + 沉浸光感材质接入点（HdsTabsFloatingStyle.systemMaterialEffect）
expectIncludes(hdsBranch, '.barOverlap(true)', 'content must keep overlapping the floating HDS tab bar')
expectIncludes(hdsBranch, 'barFloatingStyle({', 'the HDS tab bar must use the official floating style')
expectIncludes(hdsBranch, 'systemMaterialEffect:', 'the HDS tab bar must use the official systemMaterialEffect')
expectIncludes(hdsBranch, 'materialType: this.hdsMaterialType',
  'the material type must bind the resolved policy value')
expectIncludes(hdsBranch, 'materialLevel: this.hdsMaterialLevel',
  'the material level must bind the resolved policy value')

// 4. 正式策略：ADAPTIVE + ADAPTIVE（系统自适应，不默认强制 EXQUISITE）
expectIncludes(index, 'hdsMaterial.MaterialType.ADAPTIVE', 'index must default the material type to ADAPTIVE')
expectIncludes(index, 'hdsMaterial.MaterialLevel.ADAPTIVE', 'index must default the material level to ADAPTIVE')
const policy = readEts('ets/constants/HdsMaterialPolicy.ets')
expectIncludes(policy, "from '@kit.UIDesignKit'", 'the material policy must import the official HDS kit')
expectIncludes(policy, 'hdsMaterial.getSystemMaterialTypes()',
  'the policy must query the real device-supported material types')
expectIncludes(policy, 'hdsMaterial.MaterialType.ADAPTIVE', 'the policy must resolve the ADAPTIVE material type')
expectIncludes(policy, 'hdsMaterial.MaterialLevel.ADAPTIVE', 'the policy must resolve the ADAPTIVE material level')
expectIncludes(policy, 'hdsMaterial.MaterialType.IMMERSIVE',
  'the policy must check IMMERSIVE support for the dev log')
expectAbsent(policy, 'MaterialLevel.EXQUISITE',
  'the official policy must not force the EXQUISITE material level')
expectIncludes(policy, 'IMMERSIVE supported', 'the policy must keep the IMMERSIVE support dev log')
expectIncludes(policy, 'try {', 'the policy must guard the device query with try/catch')
expectIncludes(policy, '} catch', 'the policy must catch every failure without breaking startup')
expectIncludes(policy, 'new Array<hdsMaterial.MaterialType>()',
  'the policy must degrade to an empty type list on failure')

// 5. 全项目无 API26-only 沉浸 API 残留
const api26Tokens = ['uiMaterial', 'ImmersiveMaterial', 'ImmersiveStyle', 'getMaterialInfo',
  'lightEffect', '.systemMaterial(', 'systemMaterial:', 'scrollEffectOptions', 'COMMON_BLUR',
  'GRADUAL_BLUR', 'ohos.arkui.UIMaterial.state']
for (const file of allEtsFiles()) {
  const relative = path.relative(etsRoot, file).split(path.sep).join('/')
  const source = fs.readFileSync(file, 'utf8')
  for (const token of api26Tokens) {
    expectAbsent(source, token, relative + ' must not use the API 26-only token ' + token)
  }
}

// 6. HDS 底栏区域不存在人工玻璃模拟
for (const token of ['backgroundColor', 'backgroundBlurStyle', 'backgroundEffect', '.blur(', '.shadow(',
  'backdropFilter', 'linearGradient', 'Canvas(', '.opacity(']) {
  expectAbsent(hdsBranch, token, 'the HDS tab bar must not stack artificial glass (' + token + ')')
}
for (const token of ["'#FFFFFF'", "'#000000'"]) {
  expectAbsent(hdsBranch, token, 'the HDS tab bar must not hardcode material backgrounds (' + token + ')')
}

// 7. 四个 Tab 顺序与内容保持（首页、题库、错题、我的）
expectIncludes(index, "this.TabBarItem(MainTabIndex.HOME, '首页', $r('sys.symbol.house_fill'))",
  'home tab must stay first')
expectIncludes(index, "this.TabBarItem(MainTabIndex.BOOKS, '题库', $r('sys.symbol.book'))",
  'books tab must stay second')
expectIncludes(index, "this.TabBarItem(MainTabIndex.WRONG_QUESTIONS, '错题',",
  'wrong-questions tab must stay third')
expectIncludes(index, "this.TabBarItem(MainTabIndex.MINE, '我的', $r('sys.symbol.person_fill'))",
  'mine tab must stay fourth')
for (const page of ['HomePage({', 'BooksPage({', 'WrongQuestionsPage({', 'MinePage({']) {
  expectIncludes(index, page, 'the business page ' + page + ' must remain mounted')
}
const tabContentsCalls = index.split('this.TabContents()').length - 1
if (tabContentsCalls !== 1) {
  throw new Error('the official path must mount the shared TabContents builder exactly once')
}

// 8. Navigation 保留（STACK 标题栏、导入工具栏、Stack 模式），不迁移 HdsNavigation
for (const file of allEtsFiles()) {
  const relative = path.relative(etsRoot, file).split(path.sep).join('/')
  expectAbsent(fs.readFileSync(file, 'utf8'), 'HdsNavigation', relative + ' must not migrate Navigation to HDS')
}
expectIncludes(index, 'Navigation() {', 'index must keep the native Navigation root')
expectIncludes(index, 'barStyle: BarStyle.STACK', 'the title bar must use the API 24 supported STACK style')
expectIncludes(index, 'toolbarConfiguration(', 'the books import toolbar must remain')
expectIncludes(index, 'NavigationMode.Stack', 'the Navigation must stay in stack mode')

// 9. 二级页面标题栏：仅保留 API24 可用的 BarStyle，无 API26 材质字段
const detailPages = ['pages/QuestionListPage.ets', 'pages/QuestionDetailPage.ets',
  'pages/WrongQuestionDetailPage.ets', 'pages/EditQuestionPage.ets', 'pages/ImportBankPage.ets',
  'pages/PdfImportSetupPage.ets', 'pages/PdfImportProgressPage.ets', 'pages/PdfImportReviewPage.ets']
for (const page of detailPages) {
  const source = readEts('ets/' + page)
  expectIncludes(source, 'barStyle: BarStyle.STANDARD', page + ' must keep the API 24 STANDARD title bar')
  expectAbsent(source, 'systemMaterial', page + ' must drop the API 26 title bar material')
  expectAbsent(source, 'ImmersiveMaterials', page + ' must drop the API 26 material import')
}

// 10. easy_go.json 未修改
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

// 11. 业务模块未修改
const forbiddenServices = [
  'services/CloudQuestionRepository.ets',
  'services/CloudSyncService.ets',
  'services/CloudCacheService.ets',
  'models/SyncModels.ets',
  'services/CloudImportService.ets',
  'services/ApiHttpClient.ets',
  'services/AccountSessionService.ets',
  'services/DatabaseService.ets',
  'services/ConnectivityPolicy.ets',
  'services/RemoteOperationApplier.ets'
]
const uiTokens = ['@kit.UIDesignKit', 'HdsTabs', 'hdsMaterial', 'systemMaterialEffect', 'HdsMaterialPolicy']
for (const relative of forbiddenServices) {
  const source = readEts('ets/' + relative)
  for (const token of uiTokens) {
    expectAbsent(source, token, relative + ' must stay untouched by the API 24 bottom bar migration')
  }
}

// 12. server 未修改
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
  for (const token of uiTokens) {
    expectAbsent(source, token, relative + ' must stay untouched by the API 24 bottom bar migration')
  }
}

process.stdout.write('API 24 HdsTabs contracts passed\n')
