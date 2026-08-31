const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const root = path.resolve(__dirname, '..', 'main', 'ets')
const modelPath = path.join(root, 'models', 'CloudImportModels.ets')
const apiPath = path.join(root, 'services', 'CloudImportApi.ets')
const servicePath = path.join(root, 'services', 'CloudImportService.ets')
const clientPath = path.join(root, 'services', 'ApiHttpClient.ets')

for (const filePath of [modelPath, apiPath, servicePath, clientPath]) {
  assert.equal(fs.existsSync(filePath), true, `Missing Task 9 source: ${filePath}`)
}

const models = fs.readFileSync(modelPath, 'utf8')
const api = fs.readFileSync(apiPath, 'utf8')
const service = fs.readFileSync(servicePath, 'utf8')
const client = fs.readFileSync(clientPath, 'utf8')
const cloudSources = models + '\n' + api + '\n' + service + '\n' + client

for (const className of [
  'CloudImportJob',
  'CloudImportProgress',
  'CloudImportDraft',
  'CloudImportDraftQuestion',
  'CloudImportArtifact',
  'ConfirmImportResult',
  'CreateCloudImportRequest',
  'CompleteCloudImportRequest',
  'ConfirmCloudImportRequest'
]) {
  assert.match(models, new RegExp(`export class ${className}\\b`))
}

for (const status of [
  'uploading',
  'queued',
  'processing',
  'review',
  'confirmed',
  'failed',
  'cancelled',
  'expired'
]) {
  assert.match(models, new RegExp(`['"]${status}['"]`))
}

assert.match(api, /const PART_BYTES:\s*number = 4 \* 1024 \* 1024/)
assert.match(api + '\n' + client, /X-Part-Sha256/)
assert.match(api + '\n' + client, /application\/octet-stream/)
assert.match(api, /\/v1\/imports\/pdf/)
assert.match(api, /\/parts\//)
assert.match(api, /\/complete/)
assert.match(api, /\/draft/)
assert.match(api, /\/confirm/)
assert.match(api, /\/artifacts\//)
assert.match(api, /\/artifacts\/ack/)
assert.match(api, /cancel/)
assert.match(api, /static async create[\s\S]*?'\/v1\/imports\/pdf'[\s\S]*?accessToken, 201\)/)
assert.match(api, /static async uploadPart[\s\S]*?'\/parts\/'[\s\S]*?authorizedBinaryPut[\s\S]*?204, jobId\)/)
assert.match(api, /static async complete[\s\S]*?'\/complete'[\s\S]*?accessToken, 202, jobId\)/)
assert.match(api, /static async getJob[\s\S]*?authorizedGetExpecting[\s\S]*?accessToken, 200\)/)
assert.match(api, /static async getDraft[\s\S]*?'\/draft'[\s\S]*?accessToken, 200\)/)
assert.match(api, /static async confirm[\s\S]*?'\/confirm'[\s\S]*?accessToken, 201\)/)
assert.match(api, /static async downloadArtifact[\s\S]*?'\/artifacts\/'[\s\S]*?authorizedBinaryDownload[\s\S]*?200/)
assert.match(api, /static async acknowledgeArtifacts[\s\S]*?'\/artifacts\/ack'[\s\S]*?accessToken, 204\)/)
assert.match(api, /static async cancel[\s\S]*?authorizedDelete[\s\S]*?accessToken, 204\)/)

assert.match(client, /authorizedBinaryPut/)
assert.match(client, /authorizedBinaryDownload/)
assert.match(client, /HttpDataType\.ARRAY_BUFFER/)
assert.match(client, /'Authorization': 'Bearer ' \+ accessToken/)
assert.match(client, /ApiConfig\.BASE_URL/)
assert.match(client, /ApiConfig\.CA_PATH/)
assert.match(client, /ApiConfig\.CONNECT_TIMEOUT_MS/)
assert.match(client, /ApiConfig\.READ_TIMEOUT_MS/)
assert.match(client, /response\.responseCode/)
assert.match(client, /cancelRequest/)
assert.match(client, /request\.destroy\(\)/)

assert.match(service, /firstMissingPart/)
assert.match(service, /AccountSessionService\.refresh/)
assert.equal((service.match(/AccountSessionService\.refresh/g) || []).length, 1)
assert.match(service, /hash\.hash\(pdfPath, 'sha256'\)\)\.toLowerCase\(\)/)
assert.match(service, /hash\.createHash\('sha256'\)/)
assert.match(service, /ApiHttpClient\.cancelRequest\(jobId\)/)
assert.match(service, /return await CloudImportService\.uploadPartsAndComplete/)
assert.match(service, /return await CloudImportService\.authorized<CompleteCloudImportResult>/)
assert.doesNotMatch(service, /OnDeviceOcrService|PdfImportCoordinator/)
assert.doesNotMatch(cloudSources, /console\.|hilog\.|Logger\./)
assert.doesNotMatch(cloudSources, /log\s*\([^\n]*(Authorization|accessToken|pdfBytes|draft|artifact)/i)

console.log('Cloud import API contracts passed')
