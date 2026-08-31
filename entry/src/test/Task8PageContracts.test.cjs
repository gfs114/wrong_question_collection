const fs = require('fs')
const path = require('path')

const sourceRoot = path.resolve(__dirname, '../main/ets')

function read(relativePath) {
  const file = path.join(sourceRoot, relativePath)
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

const minePage = read('pages/MinePage.ets')
expectIncludes(minePage, 'WrongQuestionService.clear', 'clear must use the local service')
expectIncludes(minePage, 'showAlertDialog', 'clear must require confirmation')
expectIncludes(minePage, "value: '取消'", 'clear dialog must have a side-effect-free cancel action')
expectIncludes(minePage, "value: '清空'", 'clear dialog must name the destructive action')
expectIncludes(minePage, "'已清空错题'", 'clear success feedback must be stable')
expectIncludes(minePage, 'PDF 原文件和题图始终保存在本机', 'about copy must explain on-device PDF and image storage')
expectIncludes(minePage, '错题收集 v1.0.0', 'about dialog must include the local version')

const bankCard = read('components/QuestionBankCard.ets')
expectIncludes(bankCard, 'onDelete', 'bank card must expose a typed delete action')
expectIncludes(bankCard, "Text('删除')", 'delete action must be visible')

const booksPage = read('pages/BooksPage.ets')
expectIncludes(booksPage, 'CloudQuestionRepository.deleteBank', 'bank deletion must be server-first')
expectIncludes(booksPage, 'confirmDelete', 'bank deletion must require confirmation')
expectIncludes(booksPage, "value: '删除'", 'bank dialog must name the destructive action')
expectIncludes(booksPage, "'题库已删除'", 'bank deletion success feedback must be stable')
expectIncludes(booksPage, 'bank.bankName', 'confirmation must identify the bank')

process.stdout.write('Task 8 page contracts passed\n')
