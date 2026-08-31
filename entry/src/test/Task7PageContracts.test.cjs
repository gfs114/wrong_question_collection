const fs = require('fs')
const path = require('path')

const pagesRoot = path.resolve(__dirname, '../main/ets/pages')

function readPage(name) {
  const file = path.join(pagesRoot, name + '.ets')
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

const listPage = readPage('WrongQuestionsPage')
expectIncludes(listPage, 'CloudQuestionRepository.listCachedWrongQuestions', 'subjects must be loaded from cache')
expectIncludes(listPage, 'CloudQuestionRepository.statistics', 'statistics must come from the cloud cache')
expectIncludes(listPage, "'全部'", 'all-subject chip must be visible')
expectIncludes(listPage, 'selectSubject', 'subject changes must trigger a refresh')
expectIncludes(listPage, '(item: WrongQuestionSummary): string => item.id', 'wrong rows must use stable ids')

const detailPage = readPage('WrongQuestionDetailPage')
expectIncludes(detailPage, 'CloudQuestionRepository.cachedWrongDetail', 'detail must load from the cloud cache')
expectIncludes(detailPage, '标记为已掌握', 'master action must be visible')
expectIncludes(detailPage, "CloudQuestionRepository.setWrongState(wrongId, 'mastered'", 'master action must be server-first')
expectIncludes(detailPage, "CloudQuestionRepository.setWrongState(wrongId, 'removed'", 'remove action must be server-first')
expectIncludes(detailPage, 'showAlertDialog', 'remove must require confirmation')
expectIncludes(detailPage, "value: '取消'", 'dialog buttons must use value fields')
expectIncludes(detailPage, "value: '移出'", 'destructive dialog action must be explicit')
expectIncludes(detailPage, '修改将同步到云端', 'detail must explain the cloud sync boundary')

process.stdout.write('Task 7 page contracts passed\n')
