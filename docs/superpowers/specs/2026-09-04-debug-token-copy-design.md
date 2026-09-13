# Debug Token Copy Tool Design

## Goal

Add a Debug-only tool to the Mine page that copies the current signed-in account's short-lived access token to the system pasteboard for server-side PDF import E2E testing. Release builds must expose no UI entry, and the feature must never read or expose a refresh token.

## Scope

The change is limited to the HarmonyOS application UI and its tests. It does not change authentication, server, worker, synchronization, PDF OCR, math rendering, EasyGo, HdsTabs, responsive layout, database, or SDK configuration.

## Build-mode isolation

The project already declares `debug` and `release` build modes. Hvigor generates the `BuildProfile` module for each build; its `DEBUG` constant is `true` for Debug and `false` for Release.

`MinePage.ets` will import `BuildProfile` and place the complete developer-tool section behind a build-constant guard:

```arkts
if (BuildProfile.DEBUG) {
  this.DebugToolsSection()
}
```

The section title, supporting copy, button, and click entry are all inside that guarded builder invocation. Release users therefore receive no visible or operable developer-tool entry. No new product, target, source set, SDK value, or runtime flag is introduced.

## UI placement

Add a standalone `开发辅助` section near the existing Settings section. It follows the current Mine page card, spacing, typography, color, button, accessibility, and responsive-layout patterns.

The row contains:

- Label: `复制测试 Token`
- Supporting text: `仅用于服务器 E2E 测试`
- Busy label while copying: `正在复制…`

The existing parent layout determines width and placement for compact, medium, and expanded windows. The feature adds no fixed wide layout or new responsive system.

## State and interaction

`MinePage` adds one local state value:

```arkts
@State copyingTestToken: boolean = false
```

The button is disabled while the operation is active. A second click while `copyingTestToken` is true returns immediately, preventing duplicate refresh requests, pasteboard writes, and Toast messages.

## Token and pasteboard flow

The click handler performs this sequence:

1. Resolve the page host `Context`.
2. Set `copyingTestToken` to true before starting any account request.
3. Call `AccountSessionService.state(context)`.
4. If the account is not signed in, show `请先登录华为账号` and stop.
5. Call only `AccountSessionService.accessToken(context)` for token acquisition.
6. Let the existing session service return a fresh in-memory token or perform its existing refresh flow when the access token has expired.
7. If the returned string is empty, show `暂时无法获取测试 Token` and stop.
8. Create plain-text paste data with the API24-compatible `@kit.BasicServicesKit` pasteboard API and write it with `getSystemPasteboard().setData(...)`.
9. Show `测试 Token 已复制` after a successful write.
10. Restore `copyingTestToken` in `finally` for every signed-in, signed-out, success, and failure path.

The token remains a method-local variable and is passed only to the system pasteboard call.

## Error handling

- Missing UI context: `暂时无法获取测试 Token`.
- Signed-out account: `请先登录华为账号`; token acquisition is not attempted.
- Empty access token: `暂时无法获取测试 Token`; pasteboard is not written.
- Access-token acquisition or refresh failure: `暂时无法获取测试 Token`.
- Pasteboard creation or write failure: `复制失败，请重试`.
- Page disappearance or any asynchronous rejection: all promises are awaited inside `try/catch/finally`, so no unhandled rejection escapes and busy state is restored.

Token acquisition and pasteboard writing use separate guarded phases so a pasteboard failure is not reported as an authentication failure.

## Security constraints

The implementation must satisfy all of the following:

- It calls `AccountSessionService.accessToken(context)` as the sole token source.
- It never calls `AccountSessionStore.refreshToken()` or otherwise reads refresh-token storage.
- It never logs, renders, persists, serializes, snapshots, or includes the access token in an error message.
- It never writes the access token to files, Preferences, application state, or temporary storage.
- It does not modify refresh rotation, logout, Huawei login, server authentication, or token validation.
- Release UI contains no developer section, supporting text, button, or click entry.

## Test strategy

Add `entry/src/test/DebugTokenCopyContracts.test.cjs`, following the repository's existing source-contract test style. It verifies:

1. The Debug-only builder invocation is guarded by `BuildProfile.DEBUG`.
2. The button, label, and supporting text belong to the developer section.
3. The handler checks signed-in state before calling `AccountSessionService.accessToken(context)`.
4. Success writes the token through the system pasteboard and shows the success Toast.
5. Existing `AccountSessionService.accessToken()` retains its memory-token and refresh behavior.
6. Empty token and token exceptions do not write to the pasteboard and use the token-failure Toast.
7. Pasteboard exceptions use the copy-failure Toast.
8. `copyingTestToken` blocks repeated work and is restored in `finally`.
9. The added production source contains no token logging, token UI rendering, token persistence, or refresh-token access.

Validation runs the new contract test, the repository's existing Node contract tests, ArkTS compilation, Debug assembly, and Release assembly. Build output is checked to confirm Debug and Release each generate the expected `BuildProfile.DEBUG` value. Signing-environment failures, if any, are reported separately from compilation failures.

## Files

Expected changes:

- Modify `entry/src/main/ets/pages/MinePage.ets`.
- Add `entry/src/test/DebugTokenCopyContracts.test.cjs`.
- Add this design document and a subsequent implementation plan.

No authentication, server, worker, SDK, EasyGo, HdsTabs, MathContentView, database, or build-profile file is modified.
