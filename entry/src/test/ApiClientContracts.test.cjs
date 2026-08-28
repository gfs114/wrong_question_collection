const fs = require('fs')
const path = require('path')

const projectRoot = path.resolve(__dirname, '../../..')

function read(relativePath) {
  const file = path.join(projectRoot, relativePath)
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

function expectMissing(source, text, message) {
  if (source.includes(text)) {
    throw new Error(message + ': ' + text)
  }
}

const apiConfig = read('entry/src/main/ets/constants/ApiConfig.ets')
const client = read('entry/src/main/ets/services/ApiHttpClient.ets')
const networkConfig = read('entry/src/main/resources/base/profile/network_config.json')
const ca = read('entry/src/main/resources/resfile/appCaCert/ca.crt')

expectIncludes(apiConfig, "https://114.132.197.160", 'API must use the public HTTPS endpoint')
expectMissing(apiConfig, "http://114.132.197.160", 'API must never fall back to cleartext HTTP')
expectIncludes(apiConfig, '/data/storage/el1/bundle/entry/resources/resfile/appCaCert',
  'API must point at the bundled CA directory')
expectIncludes(client, 'caPath: ApiConfig.CA_PATH', 'HTTP requests must use the bundled CA')
expectIncludes(client, 'connectTimeout: ApiConfig.CONNECT_TIMEOUT_MS', 'HTTP client needs a connect timeout')
expectIncludes(client, 'readTimeout: ApiConfig.READ_TIMEOUT_MS', 'HTTP client needs a read timeout')
expectIncludes(client, "'Content-Type': 'application/json'", 'HTTP client must send JSON')
expectIncludes(client, 'response.responseCode < 200 || response.responseCode >= 300',
  'HTTP client must reject non-success responses')
expectIncludes(networkConfig, '"trust-global-user-ca": false', 'global user CA trust must be disabled')
expectIncludes(networkConfig, '"trust-current-user-ca": false', 'current-user CA trust must be disabled')
expectIncludes(networkConfig, 'appCaCert', 'network policy must trust the bundled app CA')
expectIncludes(ca, '-----BEGIN CERTIFICATE-----', 'CA must be a PEM certificate')
expectIncludes(ca, '-----END CERTIFICATE-----', 'CA must be a complete PEM certificate')
expectMissing(ca, 'placeholder', 'CA must not be a placeholder')

const sources = apiConfig + client
expectMissing(sources, 'Client Secret', 'client source must not contain a Huawei client secret')
if (/[a-f0-9]{64}/i.test(sources)) {
  throw new Error('client source must not contain a secret-like 64-character hexadecimal value')
}

process.stdout.write('API client contracts passed\n')
