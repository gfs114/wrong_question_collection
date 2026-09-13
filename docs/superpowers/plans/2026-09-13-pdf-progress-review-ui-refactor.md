# AI PDF Progress and Review UI Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the approved native-workbook visual system to the AI PDF recognition progress and question review pages without changing recognition, cleanup, review, or save behavior.

**Architecture:** Keep every existing business method and adapter boundary in place. Add only responsive window observation, presentation helpers, ArkUI builders, and UI contracts. Progress remains a focused single-task surface; review remains the existing all-question editable flow, with responsive source-image/editor composition rather than a new selection state.

**Tech Stack:** HarmonyOS ArkTS/ArkUI, project `ResponsiveLayout`, `WindowSizeObserver`, `UiStyle`, Node.js contract tests, DevEco hvigor, hdc.

---

### Task 1: Lock the progress-page contract

**Files:**
- Modify: `entry/src/test/UiRemediationContracts.test.cjs`
- Test: `entry/src/test/UiRemediationContracts.test.cjs`

- [x] Add a contract requiring `PdfAiImportProgressPage.ets` to use `ResponsiveLayout`, `WindowSizeObserver`, `UiStyle`, all four safe-area edges, a top-aligned content builder, persistent status/action builders, `UiStyle.TOUCH_TARGET`, and themed action/error colors.
- [x] Require clear labels such as `识别进度`, `当前处理`, `已完成页数`, and `已识别题目`; reject `AI 视觉识别（推荐）` from the Builder section.
- [x] Run `node --test entry/src/test/UiRemediationContracts.test.cjs` and verify the new contract fails because the old page lacks the required structure.

### Task 2: Refactor the progress page

**Files:**
- Modify: `entry/src/main/ets/pages/PdfAiImportProgressPage.ets`
- Test: `entry/src/test/UiRemediationContracts.test.cjs`

- [x] Add window-size state and observer lifecycle following `PdfAiImportSetupPage.ets`; keep `startImport`, cancellation, cleanup, account revalidation, routing, and error mapping unchanged.
- [x] Add presentation-only helpers for bounded content width and progress summaries.
- [x] Replace the old centered card with builders for a top-aligned recognition overview, persistent status notice, and state-dependent action area.
- [x] Keep cancellation and every recovery action wired to its current method and guard. Give every major action at least `UiStyle.TOUCH_TARGET` height and explicit accessibility text.
- [x] Apply theme roles and top/bottom/left/right safe-area padding; keep status feedback and actions outside the scroll area.
- [x] Run the UI contract and the ArkTS checker for this file until both pass.

### Task 3: Lock the review-page contract

**Files:**
- Modify: `entry/src/test/UiRemediationContracts.test.cjs`
- Test: `entry/src/test/UiRemediationContracts.test.cjs`

- [x] Add a contract requiring responsive observation, native navigation back, a bounded bank summary, a question-list content builder, persistent notices/actions, and four-edge safe areas.
- [x] Require the authoritative-state branch to expose only `重新加载审核状态`, with no simultaneous `重新读取草稿` action.
- [x] Require 48vp-or-larger type/retry/manual/discard/save actions, wrapped or responsive action groups, themed selected states, and an EXPANDED source-image/editor branch.
- [x] Run the UI contract and verify it fails for the old manual blue return button, fixed 38vp type controls, and missing responsive structure.

### Task 4: Refactor the review page

**Files:**
- Modify: `entry/src/main/ets/pages/PdfImportReviewPage.ets`
- Test: `entry/src/test/UiRemediationContracts.test.cjs`

- [x] Add the same observer lifecycle without changing session/adaptor selection, edit persistence, failure retry/discard/manual conversion, reconciliation, abandon, or idempotent save behavior.
- [x] Remove the in-content `返回` button, show the native back button, and continue intercepting back through the existing `onBackPress` and `returnToImportPage` flow.
- [x] Split presentation into bank summary, failure card, source evidence, question editor, status notices, and bottom action builders.
- [x] On EXPANDED windows, place available source evidence beside the editor; otherwise keep the existing single-column reading order. Do not add question-selection state.
- [x] Give type choices and failure actions at least `UiStyle.TOUCH_TARGET` height; keep pending, navigation, authoritative-state, and save-policy guards intact.
- [x] Render exactly one recovery action when authoritative state is unknown. Keep errors/warnings and save action outside the question list.
- [x] Run the UI contract and ArkTS checker for both changed pages.

### Task 5: Regression, build, and evidence

**Files:**
- Modify: `docs/superpowers/plans/2026-09-12-ui-review-and-remediation.md`
- Create evidence under: `docs/superpowers/plans/ui-review-2026-09-12/`

- [x] Run `node --test entry/src/test/UiRemediationContracts.test.cjs`.
- [x] Run AI/PDF-related CJS contracts, then `node --test entry/src/test/*.test.cjs`; record the known `CloudCutoverContracts` server dirty-tree failure without touching `server/`.
- [x] Run ArkTS per-file checks for both pages.
- [x] Build the HAP with the configured DevEco SDK and `--no-daemon`, then run `git diff --check`.
- [x] Check device connectivity; no target was connected, so installation and new screenshots were not possible. No recognition request was initiated.
- [x] Record exact changes, verification, screenshot limitations, and follow-ups in the existing UI remediation document. Do not commit, push, merge, or create a PR.

### Task 6: Correct the review page on the connected EXPANDED device

**Files:**
- Modify: `entry/src/test/UiRemediationContracts.test.cjs`
- Modify: `entry/src/main/ets/pages/PdfImportReviewPage.ets`
- Modify: `docs/superpowers/plans/2026-09-12-ui-review-and-remediation.md`
- Create evidence under: `docs/superpowers/plans/ui-review-2026-09-12/`

- [x] **Step 1: Preserve the live-device baseline**

Capture the open review page before changing production code. Record the title/status-bar collision, the oversized failed-page evidence region, and the recognized-question content displaced below the fixed save action in `pdf-review-live-before.jpeg`.

- [x] **Step 2: Add failing review-page UI contracts**

Require the `Navigation` shell—not the inner content `Column`—to own all four `SafeAreaUtils` insets. Require a dedicated compact failed-page evidence builder, an EXPANDED `Row` that places the evidence beside failure details/actions, a bounded 200vp evidence height, and visible `待处理页` / `已识别题目` section labels.

- [x] **Step 3: Run the new contract and retain red evidence**

Run `node --test entry/src/test/UiRemediationContracts.test.cjs` and save the expected failure output to `docs/superpowers/plans/ui-review-2026-09-12/pdf-review-followup-red.tap`. The old UI must fail because safe-area padding is attached to the content body and the failed-page image uses the 300vp full-width presentation.

- [x] **Step 4: Implement the minimal presentation-only correction**

Move the existing top/bottom/left/right safe-area padding from the body `Column` to the `Navigation` chain. Keep phone failure content in one column; on EXPANDED windows render the failed-page thumbnail at a fixed 240vp width and at most 200vp height beside a weighted details column containing the exact existing error text and `FailureActions`. Add lightweight section labels inside the existing `List`; do not add selection state, gradients, shadows, adapters, or business-method changes.

- [x] **Step 5: Verify the focused change**

Run the UI contract and the ArkTS checker for `PdfImportReviewPage.ets`. Expected result: all UI contracts pass and the checker reports zero errors.

- [x] **Step 6: Run regression, build, and device validation**

Run AI/PDF CJS tests, then all client CJS tests; record the known `CloudCutoverContracts` dirty-`server/` failure separately without modifying `server/`. Build the normal debug HAP, run `git diff --check`, install it on the connected device, and capture `pdf-review-live-after.jpeg` if the review state remains reachable. Do not invoke recognition or any paid AI request.

- [x] **Step 7: Backfill evidence and outcomes**

Append exact test counts, ArkTS output, build result, diff-check result, device/install status, screenshots, and remaining UI follow-ups to `docs/superpowers/plans/2026-09-12-ui-review-and-remediation.md`.
