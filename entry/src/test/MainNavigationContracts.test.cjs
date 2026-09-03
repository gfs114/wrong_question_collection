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

function expectAbsent(source, text, message) {
  if (source.includes(text)) {
    throw new Error(message + ': ' + text)
  }
}

const index = read('pages/Index.ets')
const model = read('models/MainTab.ets')

expectIncludes(index, '@State selectedIndex: number = MainTabIndex.HOME', 'home must be the default tab')
expectIncludes(index, 'Navigation() {', 'index must be rooted in the native Navigation')
expectIncludes(index, 'HdsTabs({ barPosition: BarPosition.End, index: this.selectedIndex })',
  'index must host HdsTabs with the bottom bar')
expectIncludes(index, 'TabContent() {', 'each tab must live in a native TabContent')
expectIncludes(index, 'HomePage({', 'home page must be mounted')
expectIncludes(index, 'BooksPage({', 'books page must remain mounted')
expectIncludes(index, 'WrongQuestionsPage({', 'wrong-question page must remain mounted')
expectIncludes(index, 'MinePage({', 'mine page must remain mounted')
expectIncludes(index, 'active: this.selectedIndex === MainTabIndex.BOOKS', 'books active contract must remain')
expectIncludes(index, 'active: this.selectedIndex === MainTabIndex.WRONG_QUESTIONS',
  'wrong-question active contract must remain')
expectIncludes(index, 'active: this.selectedIndex === MainTabIndex.MINE', 'mine active contract must remain')
expectIncludes(index, '.barOverlap(true)', 'tab bar must overlap content for the floating material')
expectIncludes(index, 'barFloatingStyle({', 'tab bar must use the official HDS floating style')
expectIncludes(index, 'systemMaterialEffect:',
  'tab bar must carry the official HDS immersive material through systemMaterialEffect')
expectIncludes(index, '.title(this.titleFor(this.selectedIndex), {',
  'the title bar must follow the selected tab through Navigation.title')
expectIncludes(index, 'toolbarConfiguration(', 'the books import action must live in the Navigation toolbar')
expectAbsent(index, 'MainBottomNavigation', 'the custom bottom navigation must be gone')
expectAbsent(index, 'AppHeader', 'the simulated header must be gone')
expectAbsent(index, 'Stack({ alignContent: Alignment.Bottom })',
  'pages must not be layered with a hand-made floating bar')

const orderedLabels = ['首页', '题库', '错题', '我的']
let previousIndex = -1
for (const label of orderedLabels) {
  const currentIndex = index.indexOf("this.TabBarItem(MainTabIndex." +
    ['HOME', 'BOOKS', 'WRONG_QUESTIONS', 'MINE'][orderedLabels.indexOf(label)] +
    ", '" + label + "'")
  if (currentIndex <= previousIndex) {
    throw new Error('tab order must be 首页、题库、错题、我的')
  }
  previousIndex = currentIndex
}

if (index.includes("'+'") || index.includes('plus_circle')) {
  throw new Error('tab bar must not include a center plus item')
}
expectIncludes(model, 'HOME = 0', 'home index must remain stable')
expectIncludes(model, 'BOOKS = 1', 'books index must remain stable')
expectIncludes(model, 'WRONG_QUESTIONS = 2', 'wrong-question index must remain stable')
expectIncludes(model, 'MINE = 3', 'mine index must remain stable')

process.stdout.write('Main navigation contracts passed\n')
