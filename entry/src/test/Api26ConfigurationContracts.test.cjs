const fs = require('fs')
const path = require('path')

const projectRoot = path.resolve(__dirname, '../../..')
const buildProfile = fs.readFileSync(path.join(projectRoot, 'build-profile.json5'), 'utf8')
const moduleProfile = fs.readFileSync(path.join(projectRoot, 'entry/src/main/module.json5'), 'utf8')

function expectIncludes(source, text, message) {
  if (!source.includes(text)) {
    throw new Error(message + ': ' + text)
  }
}

expectIncludes(buildProfile, '"targetSdkVersion": "26.0.0"',
  'the application must target API 26')
expectIncludes(buildProfile, '"compatibleSdkVersion": "26.0.0"',
  'the API 26-only build must require an API 26 device')
expectIncludes(moduleProfile, '"name": "ohos.arkui.UIMaterial.state"',
  'the entry module must enable ArkUI system materials')
expectIncludes(moduleProfile, '"value": "enable"',
  'the entry module must enable immersive materials')

process.stdout.write('API 26 configuration contracts passed\n')
