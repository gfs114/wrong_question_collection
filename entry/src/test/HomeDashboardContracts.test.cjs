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

const model = read('models/HomeDashboard.ets')
const service = read('services/HomeDashboardService.ets')

expectIncludes(model, 'class HomeDashboardMath', 'dashboard calculations must be independently testable')
expectIncludes(model, 'masteryRate', 'dashboard must calculate a bounded mastery rate')
expectIncludes(model, 'slice(0, 3)', 'recent collections must be bounded to three items')
expectIncludes(service, 'StatisticsService.load()', 'dashboard must load real statistics')
expectIncludes(service, 'QuestionBankService.listBanks()', 'dashboard must load recent books')
expectIncludes(service, 'WrongQuestionService.listSummaries(new WrongQuestionFilter(), 3, 0)',
  'dashboard must load the three most recent wrong questions')

process.stdout.write('Home dashboard contracts passed\n')
