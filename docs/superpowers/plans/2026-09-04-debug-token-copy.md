# Debug Token Copy Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Debug-only Mine-page tool that obtains the current account's valid access token through `AccountSessionService`, copies it to the HarmonyOS system pasteboard, and remains completely absent from Release UI.

**Architecture:** `MinePage` owns one busy-state flag, the guarded developer-tool UI, and a small async handler. The handler checks session state, delegates token freshness and refresh to the existing `AccountSessionService.accessToken()`, and sends the token only to `pasteboard.setData()`. The generated `BuildProfile.DEBUG` constant guards every UI insertion point without changing build profiles or SDK settings.

**Tech Stack:** HarmonyOS ArkTS/ArkUI, generated `BuildProfile`, `@kit.BasicServicesKit` pasteboard API, Node.js source-contract tests, Hvigor Debug/Release builds.

---

## File map

- Modify `entry/src/main/ets/pages/MinePage.ets`: import build/pasteboard APIs, add busy state, implement the safe copy flow, render the existing-style developer section, and guard it in both responsive branches.
- Create `entry/src/test/DebugTokenCopyContracts.test.cjs`: enforce build isolation, control flow, Toast behavior, refresh reuse, duplicate-click prevention, and token secrecy.
- Preserve `entry/src/main/ets/services/AccountSessionService.ets`: read-only dependency; no authentication changes.
- Preserve `build-profile.json5` and `entry/build-profile.json5`: use their existing Debug/Release modes without editing them.

The user explicitly requested no commit, push, or PR. All steps leave changes uncommitted in the current isolated worktree.

### Task 1: Add the failing Debug-token contract

**Files:**
- Create: `entry/src/test/DebugTokenCopyContracts.test.cjs`
- Read: `entry/src/main/ets/pages/MinePage.ets`
- Read: `entry/src/main/ets/services/AccountSessionService.ets`
- Read: `build-profile.json5`

- [ ] **Step 1: Create the complete failing contract test**

Create `entry/src/test/DebugTokenCopyContracts.test.cjs` with:

```javascript
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
  assert.match(entry, /this\.copyTestTokenSafely\(hostContext\)/)

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
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```powershell
node --test entry/src/test/DebugTokenCopyContracts.test.cjs
```

Expected: FAIL because `MinePage.ets` does not yet import `BuildProfile`/`pasteboard`, define `DebugToolsSection`, or implement the copy handlers. The failure must be a missing-feature assertion, not a syntax error in the test.

### Task 2: Implement the safe token-copy flow and Debug-only UI

**Files:**
- Modify: `entry/src/main/ets/pages/MinePage.ets:1-30`
- Modify: `entry/src/main/ets/pages/MinePage.ets:35-65`
- Modify: `entry/src/main/ets/pages/MinePage.ets:439-505`
- Modify: `entry/src/main/ets/pages/MinePage.ets:626-759`
- Modify: `entry/src/main/ets/pages/MinePage.ets:795-825`
- Test: `entry/src/test/DebugTokenCopyContracts.test.cjs`

- [ ] **Step 1: Add only the required platform imports**

At the top of `MinePage.ets`, keep the existing AbilityKit import and add:

```arkts
import { pasteboard } from '@kit.BasicServicesKit'
import * as BuildProfile from 'BuildProfile'
```

Do not add `AccountSessionStore`, logging, Preferences, file APIs, Web APIs, or third-party dependencies.

- [ ] **Step 2: Add the duplicate-click state**

Next to the existing operation-state fields, add:

```arkts
@State copyingTestToken: boolean = false
```

Do not store the token itself in `@State`, `@StorageProp`, or another component field.

- [ ] **Step 3: Add the guarded entry and fully caught async flow**

Insert these methods before `showAbout()`:

```arkts
private copyTestToken(): void {
  if (this.copyingTestToken) {
    return
  }
  const hostContext: Context | undefined = this.getUIContext().getHostContext()
  if (hostContext === undefined) {
    this.showToast('暂时无法获取测试 Token')
    return
  }
  this.copyingTestToken = true
  this.copyTestTokenSafely(hostContext)
}

private async copyTestTokenSafely(context: Context): Promise<void> {
  try {
    const session: AccountSessionState = await AccountSessionService.state(context)
    if (!session.signedIn) {
      this.showToast('请先登录华为账号')
      return
    }
    const token: string = await AccountSessionService.accessToken(context)
    if (token.length === 0) {
      this.showToast('暂时无法获取测试 Token')
      return
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, token)
      await pasteboard.getSystemPasteboard().setData(data)
    } catch {
      this.showToast('复制失败，请重试')
      return
    }
    this.showToast('测试 Token 已复制')
  } catch {
    this.showToast('暂时无法获取测试 Token')
  } finally {
    this.copyingTestToken = false
  }
}
```

The outer `try/catch/finally` contains session and access-token failures. The nested pasteboard `try/catch` preserves the distinct copy-failure Toast. No rejected promise can leave the async method, and the token exists only as a local variable passed to `pasteboard.createData`.

- [ ] **Step 4: Add the Mine-page-style developer section**

Insert this builder after `SettingsSection()` and before `build()`:

```arkts
@Builder
private DebugToolsSection() {
  SectionTitle({ title: '开发辅助' })

  Column() {
    Button() {
      Row({ space: 12 }) {
        Text('测')
          .width(36)
          .height(36)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.colors().brand)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.colors().pageBackground)
          .borderRadius(18)
        Column({ space: 2 }) {
          Text(this.copyingTestToken ? '正在复制…' : '复制测试 Token')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().textPrimary)
          Text('仅用于服务器 E2E 测试')
            .fontSize(13)
            .fontColor(this.colors().textCaption)
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Text('›')
          .fontSize(24)
          .fontColor(this.colors().textCaption)
      }
      .width('100%')
      .height(68)
    }
    .type(ButtonType.Normal)
    .width('100%')
    .height(68)
    .padding(0)
    .backgroundColor(this.colors().cardBackground)
    .enabled(!this.copyingTestToken && !this.dialogPending)
    .accessibilityText('复制测试 Token，仅用于服务器 E2E 测试')
    .onClick(() => {
      this.copyTestToken()
    })
  }
  .width('100%')
  .padding({ left: 16, right: 16 })
  .backgroundColor(this.colors().cardBackground)
  .borderRadius(CARD_RADIUS)
}
```

- [ ] **Step 5: Guard both responsive insertion points**

In the expanded layout's right column, immediately after `this.SettingsSection()`, add:

```arkts
if (BuildProfile.DEBUG) {
  this.DebugToolsSection()
}
```

In the compact/medium branch, immediately after `this.SettingsSection()`, add the same guard:

```arkts
if (BuildProfile.DEBUG) {
  this.DebugToolsSection()
}
```

Do not call `DebugToolsSection()` anywhere else. The guard must wrap the complete section invocation, not only a label or explanatory text.

- [ ] **Step 6: Run the focused test and verify GREEN**

Run:

```powershell
node --test entry/src/test/DebugTokenCopyContracts.test.cjs
```

Expected: 3 tests PASS, 0 failures.

- [ ] **Step 7: Run ArkTS static checking on the modified page**

Run:

```powershell
& 'D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' `
  'C:\Users\32773\.agents\skills\harmonyos-dev-skill\scripts\arkts-check.cjs' `
  --project . --files entry/src/main/ets/pages/MinePage.ets
```

Expected: 0 ArkTS diagnostics. If an API type differs, inspect the installed API24 declarations before changing code; do not weaken typing or switch to deprecated clipboard APIs.

### Task 3: Verify contracts, build isolation, and security

**Files:**
- Verify: `entry/src/main/ets/pages/MinePage.ets`
- Verify: `entry/src/test/DebugTokenCopyContracts.test.cjs`
- Verify unchanged: `entry/src/main/ets/services/AccountSessionService.ets`
- Verify unchanged: `entry/src/main/ets/services/AccountSessionStore.ets`
- Verify unchanged: `build-profile.json5`
- Verify unchanged: `entry/build-profile.json5`

- [ ] **Step 1: Run every Node contract test**

Run:

```powershell
Get-ChildItem entry/src/test -Filter '*.test.cjs' | ForEach-Object {
  node $_.FullName
  if ($LASTEXITCODE -ne 0) { throw $_.Name }
}
```

Expected: every CJS contract exits 0, including `DebugTokenCopyContracts.test.cjs`.

- [ ] **Step 2: Run the existing HarmonyOS test target**

Run:

```powershell
& 'D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' `
  'D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' `
  test --mode module -p product=default -p module=entry@default
```

Expected: `BUILD SUCCESSFUL`, 0 new ArkTS errors, and 0 test failures.

- [ ] **Step 3: Build Debug and verify the generated constant**

Run:

```powershell
& 'D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' `
  'D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' `
  --no-daemon --mode module -p product=default -p module=entry@default `
  -p buildMode=debug -p properties.enableSignTask=false assembleHap

Select-String -Path 'entry/build/default/generated/profile/default/BuildProfile.ets' `
  -Pattern "BUILD_MODE_NAME = 'debug'", 'DEBUG = true'
```

Expected: unsigned Debug HAP assembly succeeds and both Debug patterns are present. Disabling the sign task is an environment-only command parameter and does not change repository signing configuration.

- [ ] **Step 4: Build Release and verify the generated constant**

Run:

```powershell
& 'D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' `
  'D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' `
  --no-daemon --mode module -p product=default -p module=entry@default `
  -p buildMode=release -p properties.enableSignTask=false assembleHap

Select-String -Path 'entry/build/default/generated/profile/default/BuildProfile.ets' `
  -Pattern "BUILD_MODE_NAME = 'release'", 'DEBUG = false'
```

Expected: unsigned Release HAP assembly succeeds and both Release patterns are present. Because both calls to `DebugToolsSection()` are inside `if (BuildProfile.DEBUG)`, Release has no visible or operable developer-tool UI.

- [ ] **Step 5: Perform the static token-secrecy audit**

Run:

```powershell
rg -n "accessToken|refreshToken|hilog|console\.(log|info|debug)|pasteboard|Text\(" `
  entry/src/main/ets/pages/MinePage.ets `
  entry/src/test/DebugTokenCopyContracts.test.cjs
```

Expected manual audit:

- `accessToken` appears only in the allowed service call and contract assertions.
- `pasteboard` appears only in the platform import, plain-text data creation, write, and contract assertions.
- No complete token is logged, rendered, persisted, serialized, or placed in test snapshots.
- No feature code accesses `refreshToken` or `AccountSessionStore`.
- No `Text(token)` or `Text(accessToken)` exists.

- [ ] **Step 6: Inspect the final scoped diff without committing**

Run:

```powershell
git diff --check
git diff -- entry/src/main/ets/pages/MinePage.ets
git status --short
```

Expected: no whitespace errors; only `MinePage.ets`, the new contract test, this plan, and its design document belong to this feature. Existing unrelated math-rendering and server-script changes remain untouched. Do not commit, push, or create a PR.

