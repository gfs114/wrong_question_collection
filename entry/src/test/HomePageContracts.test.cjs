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

const page = read('pages/HomePage.ets')
const overview = read('components/HomeOverviewCard.ets')
const recent = read('components/HomeRecentSection.ets')

expectIncludes(page, "@Prop @Watch('onActiveChanged') active", 'home must load only while active')
expectIncludes(page, "@Prop @Watch('onRefreshVersionChanged') refreshVersion", 'home must refresh after mutations')
expectIncludes(page, 'HomeDashboardService.load()', 'home must load the dashboard service')
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
expectIncludes(overview, '.systemMaterial(ImmersiveMaterials.overviewCard)',
  'the primary dashboard card must use official immersive material')
expectIncludes(recent, 'items.length === 0', 'recent sections must render empty data explicitly')

process.stdout.write('Home page contracts passed\n')
