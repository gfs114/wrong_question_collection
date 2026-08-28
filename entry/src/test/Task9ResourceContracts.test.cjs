const fs = require('fs')
const path = require('path')

const projectRoot = path.resolve(__dirname, '../../..')

function read(relativePath) {
  return fs.readFileSync(path.join(projectRoot, relativePath), 'utf8')
}

function expectIncludes(source, text, message) {
  if (!source.includes(text)) {
    throw new Error(message + ': ' + text)
  }
}

const pages = JSON.parse(read('entry/src/main/resources/base/profile/main_pages.json')).src
const expectedPages = [
  'pages/Index',
  'pages/ImportBankPage',
  'pages/PdfImportSetupPage',
  'pages/PdfImportProgressPage',
  'pages/PdfImportReviewPage',
  'pages/EditQuestionPage',
  'pages/QuestionListPage',
  'pages/QuestionDetailPage',
  'pages/WrongQuestionDetailPage'
]
if (JSON.stringify(pages) !== JSON.stringify(expectedPages)) {
  throw new Error('main_pages.json must register the exact approved routes once and in order')
}

expectIncludes(read('AppScope/resources/base/element/string.json'), '错题收集', 'app label must be localized')
expectIncludes(read('entry/src/main/resources/base/element/string.json'), '本地题库与错题管理', 'module description must be localized')
expectIncludes(read('entry/src/main/resources/base/element/color.json'), '#F5F7FB', 'launch background must match the app')

const deviceTest = read('entry/src/ohosTest/ets/test/Ability.test.ets')
expectIncludes(deviceTest, 'abilityDelegatorRegistry', 'device test must obtain the official app context')
expectIncludes(deviceTest, 'DatabaseService.initialize', 'device test must initialize local storage')
expectIncludes(deviceTest, 'QuestionBankService.saveImportedBank', 'device test must insert through public services')
expectIncludes(deviceTest, 'WrongQuestionService.markMastered', 'device test must cover mastery')
expectIncludes(deviceTest, 'QuestionBankService.deleteBank', 'device test must clean up inserted rows')
expectIncludes(deviceTest, 'baseline', 'device assertions must be relative to existing app data')

if (!read('entry/src/main/module.json5').includes('ohos.permission.INTERNET')) {
  throw new Error('v1 must request INTERNET permission for account login and sync')
}

process.stdout.write('Task 9 resource contracts passed\n')
