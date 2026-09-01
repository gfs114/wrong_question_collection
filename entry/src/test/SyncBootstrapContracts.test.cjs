const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const assert = require('node:assert/strict')

const root = path.resolve(__dirname, '..', 'main', 'ets')
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), 'utf8')

test('legacy backfill stays recovery-only and is not wired into production startup', () => {
  const source = read('services/SyncBootstrapService.ets')
  const bootstrap = read('services/AppBootstrapService.ets')

  assert.doesNotMatch(bootstrap, /SyncBootstrapService\.enqueueLegacyLocalText/)
  assert.doesNotMatch(bootstrap, /SyncBootstrapService/)
  assert.match(bootstrap, /LegacyCloudMigrationService\.initialize\(context\)/)
  assert.match(source, /legacy_text_backfill_v1/)
  assert.match(source, /b\.is_sample = 0/g)
  assert.match(source, /SyncEntityType\.QUESTION_BANK/)
  assert.match(source, /SyncEntityType\.QUESTION/)
  assert.match(source, /SyncEntityType\.WRONG_QUESTION/)
  assert.match(source, /transaction\.commit\(\)/)
  assert.match(source, /transaction\.rollback\(\)/)
  assert.match(source, /state\.flush\(\)/)
  assert.doesNotMatch(source, /question_image|image_path|source_page/i)
})

test('built-in sample imports remain device-only after the outbox cutover', () => {
  const source = read('services/QuestionBankService.ets')
  const samples = read('services/SampleDataService.ets')

  assert.match(samples, /QuestionBankService\.saveImportedBank\(bank, true\)/)
  assert.match(source, /is_sample: snapshot\.isSample \? 1 : 0/)
  assert.doesNotMatch(source, /SyncOutboxService|SyncEntityType|SyncOperationType/)
})
