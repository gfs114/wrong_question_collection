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

const index = read('pages/Index.ets')
const navigation = read('components/MainBottomNavigation.ets')
const model = read('models/MainTab.ets')

expectIncludes(index, '@State selectedIndex: number = MainTabIndex.HOME', 'home must be the default tab')
expectIncludes(index, 'Stack({ alignContent: Alignment.Bottom })', 'pages and navigation must be layered')
expectIncludes(index, 'HomePage({', 'home page must be mounted')
expectIncludes(index, 'BooksPage({', 'books page must remain mounted')
expectIncludes(index, 'WrongQuestionsPage({', 'wrong-question page must remain mounted')
expectIncludes(index, 'MinePage({', 'mine page must remain mounted')
expectIncludes(index, 'active: this.selectedIndex === MainTabIndex.BOOKS', 'books active contract must remain')
expectIncludes(index, 'active: this.selectedIndex === MainTabIndex.WRONG_QUESTIONS',
  'wrong-question active contract must remain')
expectIncludes(index, 'active: this.selectedIndex === MainTabIndex.MINE', 'mine active contract must remain')
expectIncludes(navigation, '.systemMaterial(ImmersiveMaterials.navigation)',
  'navigation must use official immersive material')
expectIncludes(navigation, "this.NavigationItem('首页'", 'home must be first')
expectIncludes(navigation, "this.NavigationItem('书籍'", 'books must be second')
expectIncludes(navigation, "this.NavigationItem('错题'", 'wrong questions must be third')
expectIncludes(navigation, "this.NavigationItem('我的'", 'mine must be fourth')
expectIncludes(navigation, 'SymbolGlyph(', 'navigation must use system symbols')
expectIncludes(navigation, '.accessibilityText(label)', 'each destination must be accessible')

const orderedLabels = ['首页', '书籍', '错题', '我的']
let previousIndex = -1
for (const label of orderedLabels) {
  const currentIndex = navigation.indexOf("this.NavigationItem('" + label + "'")
  if (currentIndex <= previousIndex) {
    throw new Error('navigation order must be 首页、书籍、错题、我的')
  }
  previousIndex = currentIndex
}

if (navigation.includes("'+'") || navigation.includes('plus_circle')) {
  throw new Error('navigation must not include a center plus item')
}
expectIncludes(model, 'HOME = 0', 'home index must remain stable')
expectIncludes(model, 'BOOKS = 1', 'books index must remain stable')
expectIncludes(model, 'WRONG_QUESTIONS = 2', 'wrong-question index must remain stable')
expectIncludes(model, 'MINE = 3', 'mine index must remain stable')

process.stdout.write('Main navigation contracts passed\n')
