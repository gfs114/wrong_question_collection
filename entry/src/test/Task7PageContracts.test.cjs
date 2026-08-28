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
expectIncludes(listPage, 'WrongQuestionService.listSubjects', 'subjects must be loaded')
expectIncludes(listPage, "new WrongQuestionFilter(this.selectedSubject", 'paging must use the selected subject')
expectIncludes(listPage, "'全部'", 'all-subject chip must be visible')
expectIncludes(listPage, 'selectSubject', 'subject changes must trigger a refresh')
expectIncludes(listPage, '(item: WrongQuestionSummary): string => item.id', 'wrong rows must use stable ids')

const detailPage = readPage('WrongQuestionDetailPage')
expectIncludes(detailPage, 'WrongQuestionService.getDetail', 'detail must load through the service')
expectIncludes(detailPage, '标记为已掌握', 'master action must be visible')
expectIncludes(detailPage, 'WrongQuestionService.markMastered', 'master action must persist')
expectIncludes(detailPage, 'WrongQuestionService.remove', 'remove action must persist')
expectIncludes(detailPage, 'showAlertDialog', 'remove must require confirmation')
expectIncludes(detailPage, "value: '取消'", 'dialog buttons must use value fields')
expectIncludes(detailPage, "value: '移出'", 'destructive dialog action must be explicit')
expectIncludes(detailPage, '所有操作仅影响本机数据', 'detail must preserve the local-only boundary')

process.stdout.write('Task 7 page contracts passed\n')
