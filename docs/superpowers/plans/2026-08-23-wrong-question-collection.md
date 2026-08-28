# Wrong Question Collection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a complete local-first HarmonyOS ArkTS/ArkUI wrong-question application that imports single-choice JSON banks, persists them in relationalStore, manages wrong-question mastery, and keeps statistics synchronized.

**Architecture:** Keep ArkUI pages and reusable components separate from typed models and services. Business data lives in three relationalStore tables; a small Preferences flag records one-time sample initialization. A strict handwritten JSON reader constructs named ArkTS classes directly, avoiding `any`, `unknown`, type assertions, structural typing, and dynamic property access.

**Tech Stack:** HarmonyOS 6.1.1(24), Stage model, ArkTS, ArkUI V1 state decorators, `@kit.ArkData`, `@kit.CoreFileKit`, `@kit.ArkTS`, Hypium, hvigor.

Add short Chinese comments only where they explain a non-obvious transaction rollback, parser escape state, or tab/route refresh boundary. Do not comment self-explanatory declarations.

---

## File map

### Models and utilities

- `entry/src/main/ets/models/Question.ets`: typed question entity and type labels.
- `entry/src/main/ets/models/QuestionBank.ets`: bank entity and bank summary.
- `entry/src/main/ets/models/WrongQuestion.ets`: stored wrong question, joined list item, and filter.
- `entry/src/main/ets/models/Statistics.ets`: aggregate counters.
- `entry/src/main/ets/models/ImportResult.ets`: explicit import outcome and error code.
- `entry/src/main/ets/utils/DateUtils.ets`: deterministic date text formatting.
- `entry/src/main/ets/utils/IdUtils.ets`: collision-resistant local IDs without cloud dependencies.
- `entry/src/main/ets/utils/JsonParser.ets`: strict single-choice JSON tokenizer/parser and validator.
- `entry/src/main/ets/utils/NavigationState.ets`: typed in-memory route selection.
- `entry/src/main/ets/constants/AppTheme.ets`: colors, spacing, radii, and text sizes.

### Data and business services

- `entry/src/main/ets/services/DatabaseService.ets`: database open, schema creation, and shared store access.
- `entry/src/main/ets/services/QuestionBankService.ets`: transactional bank insert, list, lookup, and cascade delete.
- `entry/src/main/ets/services/WrongQuestionService.ets`: add, deduplicate, filter, master, remove, and clear.
- `entry/src/main/ets/services/StatisticsService.ets`: aggregate counts.
- `entry/src/main/ets/services/ImportService.ets`: DocumentViewPicker, UTF-8 read, parse, and save orchestration.
- `entry/src/main/ets/services/SampleDataService.ets`: one-time rawfile import and Preferences marker.
- `entry/src/main/ets/services/AppBootstrapService.ets`: initializes storage before visible business pages load.

### Reusable ArkUI components

- `entry/src/main/ets/components/AppHeader.ets`
- `entry/src/main/ets/components/EmptyState.ets`
- `entry/src/main/ets/components/QuestionBankCard.ets`
- `entry/src/main/ets/components/QuestionCard.ets`
- `entry/src/main/ets/components/SectionTitle.ets`
- `entry/src/main/ets/components/StatCard.ets`
- `entry/src/main/ets/components/WrongQuestionCard.ets`

### Pages and resources

- Modify `entry/src/main/ets/pages/Index.ets`: bootstrap state and three fixed tabs.
- Create `BooksPage.ets`, `WrongQuestionsPage.ets`, `MinePage.ets`: embedded root-tab components.
- Create `ImportBankPage.ets`, `QuestionListPage.ets`, `QuestionDetailPage.ets`, `WrongQuestionDetailPage.ets`: registered routes.
- Modify `entry/src/main/resources/base/profile/main_pages.json`: register five route pages.
- Modify `entry/src/main/resources/base/element/string.json`: application and module labels.
- Modify `entry/src/main/resources/base/element/color.json`: launch and app palette resources.
- Create `entry/src/main/resources/rawfile/sample_question_bank.json`: removable example bank.

### Tests

- Replace `entry/src/test/LocalUnit.test.ets`: parser, date, and pure model rule tests.
- Keep `entry/src/test/List.test.ets` as the suite entry and import the expanded test function.
- Extend `entry/src/ohosTest/ets/test/Ability.test.ets`: on-device database lifecycle smoke test when a device is available.

## Task 1: Typed domain models, theme, and deterministic utilities

**Files:**

- Create: `entry/src/main/ets/models/Question.ets`
- Create: `entry/src/main/ets/models/QuestionBank.ets`
- Create: `entry/src/main/ets/models/WrongQuestion.ets`
- Create: `entry/src/main/ets/models/Statistics.ets`
- Create: `entry/src/main/ets/models/ImportResult.ets`
- Create: `entry/src/main/ets/constants/AppTheme.ets`
- Create: `entry/src/main/ets/utils/DateUtils.ets`
- Create: `entry/src/main/ets/utils/IdUtils.ets`
- Create: `entry/src/main/ets/utils/NavigationState.ets`

- [ ] **Step 1: Define constructor-based named models**

Use classes with initialized fields and constructors. The public shapes are:

```typescript
export class Question {
  id: string
  bankId: string
  type: string
  question: string
  options: Array<string>
  answer: string
  analysis: string

  constructor(id: string, bankId: string, type: string, question: string,
    options: Array<string>, answer: string, analysis: string) {
    this.id = id
    this.bankId = bankId
    this.type = type
    this.question = question
    this.options = options
    this.answer = answer
    this.analysis = analysis
  }

  getTypeLabel(): string {
    return this.type === 'single_choice' ? '单选题' : '未知题型'
  }
}
```

`QuestionBank`, `QuestionBankSummary`, `WrongQuestion`, `WrongQuestionListItem`, `WrongQuestionFilter`, `Statistics`, `ImportResult`, and `ImportErrorCode` follow the same constructor pattern. `WrongQuestionFilter` contains `subject`, `bankId`, `masteredMode`, `startTime`, and `endTime`; empty strings and `-1` mean no filter.

- [ ] **Step 2: Define theme constants as direct named exports**

```typescript
export const COLOR_PRIMARY: string = '#0A59F7'
export const COLOR_PAGE_BG: string = '#F5F7FB'
export const COLOR_CARD_BG: string = '#FFFFFF'
export const COLOR_TEXT_PRIMARY: string = '#17233C'
export const COLOR_TEXT_SECONDARY: string = '#6B768A'
export const COLOR_SUCCESS: string = '#14966A'
export const COLOR_DANGER: string = '#D94848'
export const PAGE_PADDING: number = 20
export const CARD_RADIUS: number = 20
export const CARD_GAP: number = 12
```

- [ ] **Step 3: Implement date and ID utilities**

`DateUtils.formatDate(timestamp)` returns `YYYY-MM-DD`; `formatDateTime(timestamp)` returns `YYYY-MM-DD HH:mm`. Pad with an explicit helper method and string concatenation, never template literals. `IdUtils.create(prefix)` concatenates prefix, `Date.now()`, and an incrementing process-local counter.

- [ ] **Step 4: Implement typed navigation selection**

`NavigationState` is a singleton class with `selectBank(bankId)`, `selectQuestion(questionId, bankId, orderedIds, index)`, `selectWrongQuestion(wrongId)`, `moveQuestion(delta)`, and typed getters. It returns empty strings when no selection exists and copies arrays with `slice()`.

- [ ] **Step 5: Run ArkTS checks**

Run the HarmonyOS skill checker against every file in this task using DevEco Studio's Node:

```powershell
$env:DEVECO_HOME = 'D:\Program Files\Huawei\DevEco Studio'
& 'D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Users\32773\.codex\skills\harmonyos-dev-skill\scripts\arkts-check.cjs' --project 'C:\Users\32773\.codex\worktrees\fd0e\openHarmony\wrong_question_collection' --files entry/src/main/ets/models/Question.ets entry/src/main/ets/models/QuestionBank.ets entry/src/main/ets/models/WrongQuestion.ets entry/src/main/ets/models/Statistics.ets entry/src/main/ets/models/ImportResult.ets entry/src/main/ets/constants/AppTheme.ets entry/src/main/ets/utils/DateUtils.ets entry/src/main/ets/utils/IdUtils.ets entry/src/main/ets/utils/NavigationState.ets
```

Expected: JSON result reports zero ArkTS diagnostics for these files.

- [ ] **Step 6: Commit**

```powershell
git add entry/src/main/ets/models entry/src/main/ets/constants entry/src/main/ets/utils/DateUtils.ets entry/src/main/ets/utils/IdUtils.ets entry/src/main/ets/utils/NavigationState.ets
git commit -m "feat: add typed wrong question domain models"
```

## Task 2: Strict JSON parser with test-first validation

**Files:**

- Create: `entry/src/main/ets/utils/JsonParser.ets`
- Modify: `entry/src/test/LocalUnit.test.ets`

- [ ] **Step 1: Write failing parser and date tests**

Replace the starter assertion with explicit cases:

```typescript
import { describe, it, expect } from '@ohos/hypium'
import { JsonParser } from '../main/ets/utils/JsonParser'
import { DateUtils } from '../main/ets/utils/DateUtils'

export default function localUnitTest(): void {
  describe('wrongQuestionCore', () => {
    it('parsesValidSingleChoiceBank', 0, () => {
      const text: string = '{"bankName":"数学示例","subject":"数学","questions":[{"id":"1","type":"single_choice","question":"1 + 1 = ?","options":["A. 1","B. 2"],"answer":"B","analysis":"1 + 1 = 2。"}]}'
      const bank = JsonParser.parse(text)
      expect(bank.bankName).assertEqual('数学示例')
      expect(bank.questions.length).assertEqual(1)
      expect(bank.questions[0].answer).assertEqual('B')
    })

    it('rejectsAnswerWithoutMatchingOption', 0, () => {
      const text: string = '{"bankName":"数学示例","subject":"数学","questions":[{"id":"1","type":"single_choice","question":"1 + 1 = ?","options":["A. 1","B. 2"],"answer":"C","analysis":"解析"}]}'
      let rejected: boolean = false
      try {
        JsonParser.parse(text)
      } catch (err) {
        rejected = true
      }
      expect(rejected).assertTrue()
    })

    it('formatsDateWithPadding', 0, () => {
      expect(DateUtils.formatDate(1767225600000)).assertEqual('2026-01-01')
    })
  })
}
```

- [ ] **Step 2: Run tests or compile the suite to verify the parser import fails**

Run the DevEco local-test command:

```powershell
$env:DEVECO_HOME = 'D:\Program Files\Huawei\DevEco Studio'
$env:DEVECO_SDK_HOME = 'D:\Program Files\Huawei\DevEco Studio\sdk'
& 'D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' test --mode module -p module=entry@default
```

Expected: failure because `JsonParser.ets` does not exist. If the sandbox blocks DevEco's user cache, request escalation and rerun the same command unchanged.

- [ ] **Step 3: Implement a tokenizer that never constructs dynamic objects**

`JsonParser.ets` contains a private `JsonReader` class with `text`, `index`, `skipWhitespace()`, `expect(character)`, `peek()`, `readString()`, `readStringArray()`, and `skipValue()`. Character reads use `charAt(index)`, not dynamic string property access. `readString()` handles `\"`, `\\`, `\/`, `\b`, `\f`, `\n`, `\r`, `\t`, and four-digit `\uXXXX` escapes. `skipValue()` recursively consumes strings, numbers, booleans, null, arrays, and objects for unrecognized fields.

- [ ] **Step 4: Parse directly into named classes**

`JsonParser.parse(text)` reads the root keys through a `switch`, constructs `Question` instances through `readQuestion()`, rejects duplicate source IDs, validates required strings, verifies `single_choice`, requires at least two options, and checks that one option begins with `answer + '.'` or `answer + '．'`. It returns a `QuestionBank` whose `bankId` fields remain empty until import assigns IDs.

The exported API is exactly:

```typescript
export class JsonParser {
  static parse(text: string): QuestionBank
}
```

- [ ] **Step 5: Run ArkTS checks and tests**

Run `arkts-check` on `JsonParser.ets`, `DateUtils.ets`, and `LocalUnit.test.ets`, then rerun the exact `hvigorw.js test --mode module -p module=entry@default` command from Step 2. Expected: all three test cases pass.

- [ ] **Step 6: Commit**

```powershell
git add entry/src/main/ets/utils/JsonParser.ets entry/src/test/LocalUnit.test.ets
git commit -m "feat: parse and validate imported question banks"
```

## Task 3: relationalStore schema and transactional services

**Files:**

- Create: `entry/src/main/ets/services/DatabaseService.ets`
- Create: `entry/src/main/ets/services/QuestionBankService.ets`
- Create: `entry/src/main/ets/services/WrongQuestionService.ets`
- Create: `entry/src/main/ets/services/StatisticsService.ets`

- [ ] **Step 1: Implement database initialization**

Use a typed config and explicit schema statements:

```typescript
const STORE_CONFIG: relationalStore.StoreConfig = {
  name: 'wrong_question_collection.db',
  securityLevel: relationalStore.SecurityLevel.S1
}

export class DatabaseService {
  private static store: relationalStore.RdbStore | null = null

  static async initialize(context: Context): Promise<void>
  static getStore(): relationalStore.RdbStore
}
```

`initialize` calls `relationalStore.getRdbStore`, executes `CREATE TABLE IF NOT EXISTS` for the three approved tables, and creates the four approved indexes. `getStore` throws a named `Error` when initialization has not completed.

- [ ] **Step 2: Implement bank inserts and mapping**

`QuestionBankService.saveImportedBank(bank, isSample)` assigns a unique bank ID and prefixed question IDs, begins a transaction, inserts a typed `relationalStore.ValuesBucket` for the bank, inserts all questions, commits, and rolls back in `catch`. It returns the stored bank ID.

Add `listBanks()`, `getBank(id)`, `listQuestions(bankId)`, `getQuestion(id)`, `searchQuestions(bankId, query)`, and `deleteBank(id)`. Every `ResultSet` is closed in `finally`. `deleteBank` removes wrong questions, questions, and bank rows in one transaction.

- [ ] **Step 3: Implement wrong-question behavior**

`WrongQuestionService` exposes:

```typescript
static async add(questionId: string, bankId: string, subject: string): Promise<boolean>
static async containsQuestion(questionId: string): Promise<boolean>
static async list(filter: WrongQuestionFilter): Promise<Array<WrongQuestionListItem>>
static async getDetail(wrongId: string): Promise<WrongQuestionListItem | null>
static async markMastered(wrongId: string): Promise<void>
static async remove(wrongId: string): Promise<void>
static async clear(): Promise<void>
static async listSubjects(): Promise<Array<string>>
```

`add` checks existence before insert and also relies on the database `UNIQUE(question_id)` constraint. `list` builds one parameterized SQL query with direct branches for each named filter field and never concatenates user text into SQL.

- [ ] **Step 4: Implement aggregate statistics**

`StatisticsService.load()` uses parameterized count queries and returns `new Statistics(bankCount, wrongCount, masteredCount, wrongCount - masteredCount)`.

- [ ] **Step 5: Run ArkTS checks**

Run `arkts-check` on the four service files and all referenced model files. Expected: no diagnostics, no unclosed `ResultSet` paths, and no use of forbidden ArkTS syntax.

- [ ] **Step 6: Commit**

```powershell
git add entry/src/main/ets/services/DatabaseService.ets entry/src/main/ets/services/QuestionBankService.ets entry/src/main/ets/services/WrongQuestionService.ets entry/src/main/ets/services/StatisticsService.ets
git commit -m "feat: persist question banks and wrong questions"
```

## Task 4: File import, sample initialization, and application bootstrap

**Files:**

- Create: `entry/src/main/ets/services/ImportService.ets`
- Create: `entry/src/main/ets/services/SampleDataService.ets`
- Create: `entry/src/main/ets/services/AppBootstrapService.ets`
- Create: `entry/src/main/resources/rawfile/sample_question_bank.json`

- [ ] **Step 1: Add the valid sample JSON**

Create a “数学基础示例题库” with three `single_choice` questions. Each question has four options, an answer letter, and a Chinese analysis. This file must pass the same `JsonParser.parse` call as external imports.

- [ ] **Step 2: Implement picker and read orchestration**

`ImportService.selectAndImport(context)` constructs `new picker.DocumentSelectOptions()`, sets `fileSuffixFilters = ['JSON文件|.json']` and `maxSelectNumber = 1`, then calls `new picker.DocumentViewPicker(context).select(options)`. An empty URI array returns `ImportResult.cancelled()`. A selected URI is read through `fs.readText(uri)`, parsed by `JsonParser`, and saved by `QuestionBankService`.

Map parser failures to `FORMAT_ERROR`, file failures to `READ_ERROR`, and store failures to `SAVE_ERROR`. The page maps these codes to the confirmed Chinese messages.

- [ ] **Step 3: Implement idempotent sample initialization**

`SampleDataService.ensureSample(context)` reads Preferences file `app_bootstrap`, key `sample_initialized`. If false, it obtains `sample_question_bank.json` via `context.resourceManager.getRawFileContent`, decodes with `util.TextDecoder`, parses and saves it, then writes and flushes the boolean marker. Set the marker only after a successful database insert.

- [ ] **Step 4: Implement bootstrap sequencing**

`AppBootstrapService.initialize(context)` awaits `DatabaseService.initialize(context)` and then `SampleDataService.ensureSample(context)`. A shared promise prevents duplicate initialization if multiple pages become visible during startup.

- [ ] **Step 5: Run parser tests and ArkTS checks**

Run parser tests with the rawfile content copied into a test string, then run `arkts-check` on all three services. Expected: valid sample accepted and service files report no diagnostics.

- [ ] **Step 6: Commit**

```powershell
git add entry/src/main/ets/services/ImportService.ets entry/src/main/ets/services/SampleDataService.ets entry/src/main/ets/services/AppBootstrapService.ets entry/src/main/resources/rawfile/sample_question_bank.json
git commit -m "feat: import local JSON question banks"
```

## Task 5: Shared ArkUI components and root tabs

**Files:**

- Create: all files under `entry/src/main/ets/components/` from the file map
- Create: `entry/src/main/ets/pages/BooksPage.ets`
- Create: `entry/src/main/ets/pages/WrongQuestionsPage.ets` with its empty/list shell
- Create: `entry/src/main/ets/pages/MinePage.ets` with its statistics shell
- Modify: `entry/src/main/ets/pages/Index.ets`

- [ ] **Step 1: Build primitive reusable components**

Each card receives explicit primitive `@Prop` values instead of a loose object. Clickable cards expose an `onClick: () => void` callback. `EmptyState` accepts title, description, action text, and action callback. All components use the constants from `AppTheme.ets`, stable text hierarchy, and card radius 20.

- [ ] **Step 2: Implement BooksPage states**

Use `@State banks: Array<QuestionBankSummary> = []` and `@State loading: boolean = true`. `aboutToAppear()` and a public `refresh()` load `QuestionBankService.listBanks()`. Empty state shows “还没有题库” and “点击右上角导入你的第一个题库”. Tapping a bank updates `NavigationState`, then uses `this.getUIContext().getRouter().pushUrl({ url: 'pages/QuestionListPage' })`.

- [ ] **Step 3: Replace Index with bootstrap and Tabs**

`Index` owns `@State ready`, `@State startupError`, `@State selectedIndex`, and `@State refreshVersion`. It calls `AppBootstrapService.initialize(getContext(this))` in `aboutToAppear`, increments `refreshVersion` in the page-level `onPageShow`, and passes `active` plus `refreshVersion` into each embedded root component. Root components watch those two props and reload only when active. When ready, render `Tabs({ barPosition: BarPosition.End, index: this.selectedIndex })` with exactly three direct `TabContent` children. Each `.tabBar(...)` uses a builder with an icon-like Unicode glyph and confirmed Chinese label; the selected item uses `COLOR_PRIMARY`.

- [ ] **Step 4: Trace visible interaction paths**

Confirm the launch page shows loading, then the sample bank. Confirm all three tab labels are visible, taps change tab content, and the bottom bar does not overlap scroll content.

- [ ] **Step 5: Run ArkTS checks and a debug build checkpoint**

Run `arkts-check` on every component and root-tab page. Then run a debug build through `scripts/deveco-build.cjs`. Expected: HAP build exits with code 0.

- [ ] **Step 6: Commit**

```powershell
git add entry/src/main/ets/components entry/src/main/ets/pages/Index.ets entry/src/main/ets/pages/BooksPage.ets entry/src/main/ets/pages/WrongQuestionsPage.ets entry/src/main/ets/pages/MinePage.ets
git commit -m "feat: add ArkUI root tabs and shared cards"
```

## Task 6: Import page and question browsing flow

**Files:**

- Create: `entry/src/main/ets/pages/ImportBankPage.ets`
- Create: `entry/src/main/ets/pages/QuestionListPage.ets`
- Create: `entry/src/main/ets/pages/QuestionDetailPage.ets`

- [ ] **Step 1: Implement ImportBankPage**

Render a back header, JSON format card, one primary “选择 JSON 文件” button, and visible progress/error state. Disable the button while importing. On success show Toast “题库导入成功” and call `router.back`; on cancellation only clear loading; on each error code show the approved Chinese message.

- [ ] **Step 2: Implement QuestionListPage**

Load the selected bank and questions from `NavigationState`. Bind `TextInput` to `@State query`; filter through `QuestionBankService.searchQuestions`. Render `QuestionCard` in a `List` with `question.id` as the key. A card tap stores ordered IDs and current index before opening `QuestionDetailPage`.

- [ ] **Step 3: Implement QuestionDetailPage**

Load the selected question and wrong status. Render type, question, option cards, correct answer, and analysis. Bottom actions are “上一题”, “加入错题” or “已加入错题”, and “下一题”. Boundary navigation is disabled. Adding uses `WrongQuestionService.add` and shows “已加入错题本”; a duplicate keeps the disabled state without inserting.

- [ ] **Step 4: Run ArkTS checks and build checkpoint**

Check all three pages, confirm they are listed in `main_pages.json` during Task 9, and build. Expected: no route-target or ArkTS diagnostics.

- [ ] **Step 5: Commit**

```powershell
git add entry/src/main/ets/pages/ImportBankPage.ets entry/src/main/ets/pages/QuestionListPage.ets entry/src/main/ets/pages/QuestionDetailPage.ets
git commit -m "feat: browse and collect imported questions"
```

## Task 7: Wrong-question filtering and detail management

**Files:**

- Modify: `entry/src/main/ets/pages/WrongQuestionsPage.ets`
- Create: `entry/src/main/ets/pages/WrongQuestionDetailPage.ets`

- [ ] **Step 1: Complete wrong-question list state**

Load `Statistics`, subjects, and filtered items together. Render three summary values, horizontal subject chips beginning with “全部”, and stable-key `WrongQuestionCard` rows. Empty data renders “暂无错题” and “做题时可以将不会的题加入错题本”. A card tap stores the wrong-question ID and opens the detail route.

- [ ] **Step 2: Implement WrongQuestionDetailPage**

Render the joined question, options, answer, analysis, bank, subject, and user answer only when non-empty. “标记为已掌握” updates the row and Toast; mastered rows show a disabled “已掌握”. “移出错题本” opens `showAlertDialog` with button fields named `value`; only the primary action deletes, shows Toast, and navigates back.

- [ ] **Step 3: Verify state refresh**

`WrongQuestionsPage` watches its `active` and `refreshVersion` props from `Index`; the routed detail page reloads after its own actions. Switching tabs or returning from a route must recalculate counts and filters from the service.

- [ ] **Step 4: Run ArkTS checks and build checkpoint**

Expected: no state-decorator mixing, no unstable list key, and successful HAP build.

- [ ] **Step 5: Commit**

```powershell
git add entry/src/main/ets/pages/WrongQuestionsPage.ets entry/src/main/ets/pages/WrongQuestionDetailPage.ets
git commit -m "feat: manage and filter collected wrong questions"
```

## Task 8: Mine statistics and destructive data actions

**Files:**

- Modify: `entry/src/main/ets/pages/MinePage.ets`
- Modify: `entry/src/main/ets/pages/BooksPage.ets`
- Modify: `entry/src/main/ets/services/QuestionBankService.ets`

- [ ] **Step 1: Complete MinePage**

Load `StatisticsService.load()` on appearance. Render default avatar, “学习中心”, four `StatCard` values, “数据管理”, “清空错题”, and “关于应用”. Clear uses an alert dialog with cancel side-effect free; primary action awaits `WrongQuestionService.clear`, refreshes statistics, and shows “已清空错题”. About displays local version and the text “所有学习数据仅保存在本机”.

- [ ] **Step 2: Add bank data management**

Give `QuestionBankCard` a compact delete action. Confirm with the bank name, call the transactional `deleteBank`, refresh the list, and show “题库已删除”. This also removes linked wrong questions, so the next wrong/mine page appearance recalculates counts.

- [ ] **Step 3: Verify cancellation and refresh behavior**

Cancel each dialog and confirm no service mutation is called. Perform clear/delete and confirm visible counters and empty states change.

- [ ] **Step 4: Run ArkTS checks and build checkpoint**

Expected: zero diagnostics and successful debug HAP build.

- [ ] **Step 5: Commit**

```powershell
git add entry/src/main/ets/pages/MinePage.ets entry/src/main/ets/pages/BooksPage.ets entry/src/main/ets/services/QuestionBankService.ets entry/src/main/ets/components/QuestionBankCard.ets
git commit -m "feat: add local data management and statistics"
```

## Task 9: Route registration, resources, and on-device service smoke test

**Files:**

- Modify: `entry/src/main/resources/base/profile/main_pages.json`
- Modify: `entry/src/main/resources/base/element/string.json`
- Modify: `entry/src/main/resources/base/element/color.json`
- Modify: `entry/src/ohosTest/ets/test/Ability.test.ets`

- [ ] **Step 1: Register all entry pages**

Set `main_pages.json` to exactly:

```json
{
  "src": [
    "pages/Index",
    "pages/ImportBankPage",
    "pages/QuestionListPage",
    "pages/QuestionDetailPage",
    "pages/WrongQuestionDetailPage"
  ]
}
```

- [ ] **Step 2: Update user-visible resources**

Set app/module labels to “错题收集”, module description to “本地题库与错题管理”, and launch background to `#F5F7FB`. Keep existing resource names referenced by `module.json5` and `EntryAbility.ets`.

- [ ] **Step 3: Add device database lifecycle smoke coverage**

In `Ability.test.ets`, initialize the database with the test ability context, insert a uniquely named bank through `QuestionBankService`, add one wrong question, mark it mastered, assert statistics `1` and `1` relative to the pre-test baseline, then delete the bank in `afterEach`. The test must use public services only and leave no rows behind.

- [ ] **Step 4: Run route-aware ArkTS checks**

Run `arkts-check` on all project `.ets` files. Expected: every `main_pages.json` target exists and no unknown resource name is reported.

- [ ] **Step 5: Commit**

```powershell
git add entry/src/main/resources/base/profile/main_pages.json entry/src/main/resources/base/element/string.json entry/src/main/resources/base/element/color.json entry/src/ohosTest/ets/test/Ability.test.ets
git commit -m "test: register routes and cover local storage flow"
```

## Task 10: Full verification and acceptance evidence

**Files:**

- Inspect: all modified files
- Produce: `entry/build/default/outputs/default/entry-default-signed.hap` or the exact unsigned debug HAP path reported by hvigor

- [ ] **Step 1: Run the complete ArkTS checker**

Collect every `.ets` file under `entry/src/main/ets` and pass the explicit file list to `arkts-check.cjs`. Expected: process exit 0 and zero diagnostics.

- [ ] **Step 2: Run local unit tests**

Run:

```powershell
$env:DEVECO_HOME = 'D:\Program Files\Huawei\DevEco Studio'
$env:DEVECO_SDK_HOME = 'D:\Program Files\Huawei\DevEco Studio\sdk'
& 'D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' test --mode module -p module=entry@default
```

Expected: parser, invalid answer, and date tests all pass with zero failures.

- [ ] **Step 3: Build the debug HAP**

```powershell
$env:DEVECO_HOME = 'D:\Program Files\Huawei\DevEco Studio'
$env:DEVECO_SDK_HOME = 'D:\Program Files\Huawei\DevEco Studio\sdk'
& 'D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Users\32773\.codex\skills\harmonyos-dev-skill\scripts\deveco-build.cjs' --project 'C:\Users\32773\.codex\worktrees\fd0e\openHarmony\wrong_question_collection' --build-mode debug --product default --json
```

Expected: JSON status success and HAP output path exists. The command needs permission to write DevEco's user cache under `C:\Users\32773\.hvigor`; request sandbox escalation rather than changing the project SDK.

- [ ] **Step 4: Check connected HarmonyOS targets**

Run the `harmonyos-dev` `hdc-log.cjs --action list_devices --json` helper. If no target exists, record that device interaction is unverified. If one target exists, install and start with `start-app.cjs`, then capture a screenshot with `device-screenshot.cjs`.

- [ ] **Step 5: Execute the acceptance path on a target when available**

Verify startup sample, external JSON import, bank list, question search, question detail, add wrong question, duplicate prevention, wrong subject filter, mastery, mine statistics, remove confirmation, clear confirmation, persistence after force-stop/start, and cascade cleanup after deleting a bank.

- [ ] **Step 6: Review requirements and Git diff**

Compare every section of `docs/superpowers/specs/2026-08-23-wrong-question-collection-design.md` against a reachable screen or tested service. Run `git diff --check` and `git status --short`; report unrelated pre-existing changes separately.

- [ ] **Step 7: Final commit**

```powershell
git add entry docs/superpowers/plans/2026-08-23-wrong-question-collection.md
git commit -m "feat: complete HarmonyOS wrong question collection app"
```

## Cloud boundary during implementation

No task adds a network permission, account SDK, cloud database, object storage, analytics upload, or synchronization endpoint. The only file picker reads a user-selected local URI, and all statistics come from local relationalStore queries. Account login, cross-device synchronization, cloud backup, and a shared question-bank marketplace would each require explicit cloud services and a separate design.
