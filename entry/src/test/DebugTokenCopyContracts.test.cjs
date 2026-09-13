'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { test } = require('node:test')

const projectRoot = path.resolve(__dirname, '../../..')

function read(relativePath) {
  return fs.readFileSync(path.join(projectRoot, relativePath), 'utf8')
}

function block(source, marker) {
  const markerIndex = source.indexOf(marker)
  assert.notEqual(markerIndex, -1, `missing marker: ${marker}`)
  const openIndex = source.indexOf('{', markerIndex)
  assert.notEqual(openIndex, -1, `missing opening brace: ${marker}`)
  let depth = 0
  for (let index = openIndex; index < source.length; index += 1) {
    if (source[index] === '{') depth += 1
    if (source[index] === '}') {
      depth -= 1
      if (depth === 0) return source.slice(openIndex + 1, index)
    }
  }
  throw new Error(`missing closing brace: ${marker}`)
}

const mine = read('entry/src/main/ets/pages/MinePage.ets')
const sessionService = read('entry/src/main/ets/services/AccountSessionService.ets')
const projectBuildProfile = read('build-profile.json5')

test('renders the complete developer section only behind BuildProfile.DEBUG', () => {
  assert.match(mine, /import \* as BuildProfile from 'BuildProfile'/)
  assert.match(mine, /import \{ pasteboard \} from '@kit\.BasicServicesKit'/)
  assert.match(projectBuildProfile, /"name":\s*"debug"/)
  assert.match(projectBuildProfile, /"name":\s*"release"/)

  const guardedCalls = mine.match(
    /if \(BuildProfile\.DEBUG\) \{\s*this\.DebugToolsSection\(\)\s*\}/g,
  ) || []
  assert.equal(guardedCalls.length, 2, 'both responsive branches must guard the entire section')

  const section = block(mine, 'private DebugToolsSection()')
  assert.match(section, /SectionTitle\(\{ title: '开发辅助' \}\)/)
  assert.match(section, /复制测试 Token/)
  assert.match(section, /仅用于服务器 E2E 测试/)
  assert.match(section, /\.enabled\(!this\.copyingTestToken/)
  assert.match(section, /this\.copyTestToken\(\)/)
})

test('checks login, reuses accessToken refresh, and reports every result', () => {
  const entry = block(mine, 'private copyTestToken(): void')
  const flow = block(mine, 'private async copyTestTokenSafely(context: Context): Promise<void>')

  assert.match(entry, /if \(this\.copyingTestToken\)/)
  assert.match(entry, /this\.copyingTestToken = true/)
  assert.match(entry, /this\.copyTestTokenSafely\(hostContext\)\.catch\(\(\) => \{/)

  const stateIndex = flow.indexOf('AccountSessionService.state(context)')
  const tokenIndex = flow.indexOf('AccountSessionService.accessToken(context)')
  const pasteboardIndex = flow.indexOf('pasteboard.createData(')
  const setDataIndex = flow.indexOf('.setData(data)')
  assert.ok(stateIndex >= 0 && tokenIndex > stateIndex, 'login state must be checked before token acquisition')
  assert.ok(pasteboardIndex > tokenIndex && setDataIndex > pasteboardIndex,
    'pasteboard write must happen only after token acquisition')

  assert.match(flow, /if \(!session\.signedIn\)/)
  assert.match(flow, /请先登录华为账号/)
  assert.match(flow, /if \(token\.length === 0\)/)
  assert.match(flow, /暂时无法获取测试 Token/)
  assert.match(flow, /复制失败，请重试/)
  assert.match(flow, /测试 Token 已复制/)
  assert.match(flow, /finally \{\s*this\.copyingTestToken = false\s*\}/)

  const accessToken = block(
    sessionService,
    'static async accessToken(context: Context): Promise<string>',
  )
  assert.match(accessToken, /AccountSessionTiming\.isFresh/)
  assert.match(accessToken, /return AccountSessionService\.accessTokenValue/)
  assert.match(accessToken, /return AccountSessionService\.refresh\(context\)/)
})

test('never exposes or persists either token from the Mine-page feature', () => {
  const entry = block(mine, 'private copyTestToken(): void')
  const flow = block(mine, 'private async copyTestTokenSafely(context: Context): Promise<void>')
  const section = block(mine, 'private DebugToolsSection()')
  const feature = [entry, flow, section].join('\n')

  assert.doesNotMatch(feature, /AccountSessionStore|refreshToken/)
  assert.doesNotMatch(feature, /hilog|console\.(?:log|info|debug)/)
  assert.doesNotMatch(feature, /Text\(\s*(?:token|accessToken)\s*\)/)
  assert.doesNotMatch(feature, /preferences|fileIO|writeText|writeFile/)
  assert.doesNotMatch(mine, /@State\s+(?:token|accessToken)\s*:/)
  assert.equal((flow.match(/AccountSessionService\.accessToken\(context\)/g) || []).length, 1)
})
