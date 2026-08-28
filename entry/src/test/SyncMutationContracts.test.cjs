const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const assert = require('node:assert/strict')

const root = path.resolve(__dirname, '..', 'main', 'ets')
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), 'utf8')

test('question bank writes enqueue bank and question text in their owning transaction', () => {
  const source = read('services/QuestionBankService.ets')

  assert.match(source, /enqueueImportedSnapshot\(transaction, snapshot, remoteApply\)/g)
  assert.match(source, /SyncEntityType\.QUESTION_BANK/)
  assert.match(source, /SyncEntityType\.QUESTION/)
  assert.match(source, /SyncOutboxService\.enqueue[\s\S]*transaction/)
  assert.match(source, /updateQuestion\(question: Question, remoteApply: boolean = false\)/)
  assert.match(source, /deleteBank\(id: string, remoteApply: boolean = false\)/)
})

test('wrong question mutations enqueue upsert and delete operations including clear', () => {
  const source = read('services/WrongQuestionService.ets')

  assert.match(source, /add\([^)]*remoteApply: boolean = false/)
  assert.match(source, /markMastered\(wrongId: string, remoteApply: boolean = false\)/)
  assert.match(source, /remove\(wrongId: string, remoteApply: boolean = false\)/)
  assert.match(source, /clear\(remoteApply: boolean = false\)/)
  assert.match(source, /SyncOperationType\.UPSERT/)
  assert.match(source, /SyncOperationType\.DELETE/)
  assert.match(source, /while \(resultSet\.goToNextRow\(\)\)[\s\S]*enqueueWrongQuestion/)
})

test('remote apply never echoes changes into outbox', () => {
  const bankSource = read('services/QuestionBankService.ets')
  const wrongSource = read('services/WrongQuestionService.ets')

  assert.match(bankSource, /if \(remoteApply\) \{\s*return/)
  assert.match(wrongSource, /if \(remoteApply\) \{\s*return/)
})

test('sync payload factory includes text only and excludes device image data', () => {
  const source = read('services/SyncPayloadFactory.ets')

  assert.match(source, /bankPayload/)
  assert.match(source, /questionPayload/)
  assert.match(source, /wrongQuestionPayload/)
  assert.doesNotMatch(source, /image_path|imagePath|binary|pixelMap/i)
})
