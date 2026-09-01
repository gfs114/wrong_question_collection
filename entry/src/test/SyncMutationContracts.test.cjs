const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const assert = require('node:assert/strict')

const root = path.resolve(__dirname, '..', 'main', 'ets')
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), 'utf8')

test('question bank writes no longer enqueue legacy outbox operations', () => {
  const source = read('services/QuestionBankService.ets')

  assert.doesNotMatch(source, /SyncOutboxService\.enqueue/)
  assert.doesNotMatch(source, /SyncOutboxService/)
  assert.doesNotMatch(source, /SyncEntityType|SyncOperationType/)
  assert.doesNotMatch(source, /SyncIdentityService|SyncPayloadFactory/)
  assert.match(source, /static async saveImportedBank\(bank: QuestionBank, isSample: boolean\)/)
  assert.match(source, /static async updateQuestion\(question: Question\)/)
  assert.match(source, /static async deleteBank\(id: string\)/)
})

test('wrong question mutations no longer enqueue legacy outbox operations', () => {
  const source = read('services/WrongQuestionService.ets')

  assert.doesNotMatch(source, /SyncOutboxService\.enqueue/)
  assert.doesNotMatch(source, /SyncOutboxService/)
  assert.doesNotMatch(source, /SyncEntityType|SyncOperationType/)
  assert.match(source, /static async add\(questionId: string, bankId: string, subject: string\)/)
  assert.match(source, /static async markMastered\(wrongId: string\)/)
  assert.match(source, /static async remove\(wrongId: string\)/)
  assert.match(source, /static async clear\(\)/)
})

test('online mutations are server-first through CloudQuestionRepository', () => {
  const repository = read('services/CloudQuestionRepository.ets')

  assert.match(repository, /static async updateQuestion\(question:\s*Question,\s*context:\s*Context\)/)
  assert.match(repository, /static async setWrongState\(questionUuid:\s*string,\s*status:\s*string,\s*context:\s*Context\)/)
  assert.match(repository, /static async deleteBank\(bankUuid:\s*string,\s*context:\s*Context\)/)
  assert.match(repository, /static async createBank\(bank:\s*QuestionBank,\s*context:\s*Context\)/)
  assert.match(repository, /static async clearWrongQuestions\(context:\s*Context\)/)
  assert.match(repository, /'\/v1\/sync\/push'/)
  assert.doesNotMatch(repository, /SyncOutboxService\.enqueue/)
  assert.doesNotMatch(repository, /QuestionBankService|WrongQuestionService/)
})

test('remote apply never echoes changes into outbox', () => {
  const applier = read('services/RemoteOperationApplier.ets')

  assert.doesNotMatch(applier, /SyncOutboxService\.enqueue/)
  assert.match(applier, /serverSequence/)
  assert.match(applier, /SyncSequence\.compare/)
})

test('sync payload factory includes text only and excludes device image data', () => {
  const source = read('services/SyncPayloadFactory.ets')

  assert.match(source, /bankPayload/)
  assert.match(source, /questionPayload/)
  assert.match(source, /wrongQuestionPayload/)
  assert.doesNotMatch(source, /image_path|imagePath|binary|pixelMap/i)
})
