const fs = require('fs')
const path = require('path')

const root = path.resolve(__dirname, '../main/ets/pages')

function readPage(name) {
  const file = path.join(root, name + '.ets')
  if (!fs.existsSync(file)) {
    throw new Error(name + '.ets is required')
  }
  return fs.readFileSync(file, 'utf8')
}

function expectIncludes(source, text, message) {
  if (!source.includes(text)) {
    throw new Error(message + ': ' + text)
  }
}

function expectExcludes(source, text, message) {
  if (source.includes(text)) {
    throw new Error(message + ': ' + text)
  }
}

const importPage = readPage('ImportBankPage')
expectIncludes(importPage, '选择 JSON 文件', 'import action must be visible')
expectIncludes(importPage, '题库导入成功', 'success toast must be stable')
expectIncludes(importPage, '题库格式错误，请检查 JSON 文件', 'format error must match the approved copy')
expectIncludes(importPage, '文件读取失败，请重新选择', 'read error must be user friendly')
expectIncludes(importPage, '题库保存失败，请稍后重试', 'save error must be user friendly')
expectIncludes(importPage, 'result.cancelled', 'cancelled import must be handled explicitly')
expectExcludes(importPage, 'result.message', 'raw service details must not be rendered')

const listPage = readPage('QuestionListPage')
expectIncludes(listPage, 'CloudQuestionRepository.listCachedQuestions', 'search must use the cloud cache')
expectIncludes(listPage, 'NavigationState.shared().selectQuestion', 'question order must be saved before routing')
expectIncludes(listPage, '(question: Question): string => question.id', 'list must use stable question ids')
expectIncludes(listPage, 'navigationPending', 're-entrant navigation must be guarded')

const detailPage = readPage('QuestionDetailPage')
expectIncludes(detailPage, 'CloudQuestionRepository.containsWrong', 'wrong-question status must be loaded')
expectIncludes(detailPage, 'CloudQuestionRepository.setWrongState', 'add action must be server-first')
expectIncludes(detailPage, '上一题', 'previous action must be visible')
expectIncludes(detailPage, '下一题', 'next action must be visible')
expectIncludes(detailPage, 'requestToken', 'stale async loads must be rejected')

process.stdout.write('Task 6 page contracts passed\n')
