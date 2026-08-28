const fs = require('fs')
const path = require('path')

const projectRoot = path.resolve(__dirname, '../../..')

function read(relativePath) {
  return fs.readFileSync(path.join(projectRoot, relativePath), 'utf8')
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

// 1. The manifest must grant INTERNET for account login and sync.
const moduleSource = read('entry/src/main/module.json5')
expectIncludes(moduleSource, 'ohos.permission.INTERNET', 'manifest must declare INTERNET permission')

// 2. The private CA must be bundled as a real resource and selected by both
//    the static network policy and each system HTTP request.
const networkConfig = read('entry/src/main/resources/base/profile/network_config.json')
const ca = read('entry/src/main/resources/resfile/appCaCert/ca.crt')
const apiConfig = read('entry/src/main/ets/constants/ApiConfig.ets')
const apiClient = read('entry/src/main/ets/services/ApiHttpClient.ets')
expectIncludes(networkConfig, 'appCaCert', 'network policy must use the bundled CA directory')
expectIncludes(networkConfig, '"trust-global-user-ca": false', 'global user CA trust must be disabled')
expectIncludes(networkConfig, '"trust-current-user-ca": false', 'current-user CA trust must be disabled')
expectIncludes(ca, '-----BEGIN CERTIFICATE-----', 'bundled CA must be PEM')
expectMissing(ca, 'placeholder', 'bundled CA must not be a placeholder')
expectIncludes(apiConfig, 'https://114.132.197.160', 'server endpoint must be HTTPS')
expectMissing(apiConfig, 'http://114.132.197.160', 'server endpoint must not be cleartext HTTP')
expectIncludes(apiClient, 'caPath: ApiConfig.CA_PATH', 'HTTP client must use the bundled CA')
expectIncludes(apiClient, 'createHttp', 'API client must use the system HTTP client')
expectMissing(apiClient, 'insecure', 'API client must never disable security')
expectMissing(apiClient, "'skip'", 'certificate validation must never be skipped')

process.stdout.write('Network security contracts passed\n')
