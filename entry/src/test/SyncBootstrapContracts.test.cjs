const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const assert = require('node:assert/strict')

const root = path.resolve(__dirname, '..', 'main', 'ets')
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), 'utf8')

test('bootstrap backfills legacy non-sample text exactly once', () => {
  const source = read('services/SyncBootstrapService.ets')
  const bootstrap = read('services/AppBootstrapService.ets')

  assert.match(bootstrap, /SyncBootstrapService\.enqueueLegacyLocalText\(context\)/)
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

test('built-in sample imports remain device-only', () => {
  const source = read('services/QuestionBankService.ets')

  assert.match(source, /if \(remoteApply \|\| snapshot\.isSample\) \{\s*return/)
})
