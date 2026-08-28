# On-Device PDF Question Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fully on-device PDF import flow that renders up to 20 selected pages, recognizes mixed math-question layouts, preserves cropped source images, allows review and editing, and stores the result locally without network access.

**Architecture:** Keep platform APIs behind small services: Core File Kit selects and streams a PDF into the cache, PDF Kit renders one page at a time, Core Vision Kit supplies OCR lines and coordinates, and Image Kit writes compressed question crops. Pure typed validators and parsers convert OCR lines into editable drafts; a version-2 relationalStore schema persists source-page metadata and one-to-many question images.

**Tech Stack:** HarmonyOS 6.1.1(24), Stage model, ArkTS, ArkUI V1 decorators, `@kit.PDFKit`, `@kit.CoreVisionKit`, `@kit.ImageKit`, `@kit.CoreFileKit`, `@kit.ArkData`, Hypium, Node contract tests, hvigor.

---

## Scope and SDK anchors

- PDF Kit declarations: `D:/Program Files/Huawei/DevEco Studio/sdk/default/hms/ets/api/@hms.officeservice.pdfservice.d.ts`
  - `PdfDocument.loadDocument(path)`
  - `PdfDocument.isEncrypted(path)`
  - `PdfDocument.getPageCount()`
  - `PdfDocument.getPage(index)`
  - `PdfPage.getPagePixelMap()`
  - `PdfPage.getAreaPixelMapWithOptions(matrix, width, height, options)`
  - `PdfPage.release()` and `PdfDocument.releaseDocument()`
- OCR declarations: `D:/Program Files/Huawei/DevEco Studio/sdk/default/hms/ets/api/@hms.ai.ocr.textRecognition.d.ts`
  - `textRecognition.init()`
  - `textRecognition.recognizeText({ pixelMap }, configuration)`
  - `TextRecognitionResult.blocks[].lines[].cornerPoints`
  - `textRecognition.release()`
- Image declarations: `D:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/api/@ohos.multimedia.image.d.ts`
  - `image.createImagePacker()`
  - `ImagePacker.packToFile(pixelMap, fd, { format: 'image/jpeg', quality: 88 })`
  - `PixelMap.release()` and `ImagePacker.release()`

The ArkTS implementation follows the linter-derived restrictions in `references/arkts-grammar/restrictions.md`: named classes, explicit types, no `any`, no `unknown`, no type assertions, no dynamic property access, and no template literals.

## File map

### Create

- `entry/src/main/ets/constants/PdfImportLimits.ets`: PDF, page-count, render-size, and image-quality limits.
- `entry/src/main/ets/models/QuestionImage.ets`: persisted source-image entity.
- `entry/src/main/ets/models/PdfImportModels.ets`: selection, settings, OCR line, crop, draft, progress, and error models.
- `entry/src/main/ets/utils/PdfImportValidator.ets`: pure filename, file-size, and page-range validation.
- `entry/src/main/ets/utils/PdfQuestionParser.ets`: pure OCR line sorting, question boundaries, cross-page merging, option parsing, and type classification.
- `entry/src/main/ets/utils/PdfImportState.ets`: typed in-memory handoff between PDF pages.
- `entry/src/main/ets/services/PdfImportService.ets`: picker, streaming cache copy, PDF metadata, and temporary-file cleanup.
- `entry/src/main/ets/services/OnDeviceOcrService.ets`: Core Vision Kit lifecycle and typed line conversion.
- `entry/src/main/ets/services/QuestionImageService.ets`: crop rendering, JPEG persistence, commit, rollback, and deletion.
- `entry/src/main/ets/services/PdfImportCoordinator.ets`: sequential render/OCR/parse/crop pipeline and cancellation.
- `entry/src/main/ets/components/QuestionSourceImages.ets`: reusable local-source-image display.
- `entry/src/main/ets/pages/PdfImportSetupPage.ets`: subject and page-range form.
- `entry/src/main/ets/pages/PdfImportProgressPage.ets`: progress, cancellation, partial failure, and routing.
- `entry/src/main/ets/pages/PdfImportReviewPage.ets`: draft review, editing, deletion, and transactional save.
- `entry/src/main/ets/pages/EditQuestionPage.ets`: edit a saved question after import.
- `entry/src/test/PdfImportContracts.test.cjs`: route, permission, API import, and visible-copy contracts.

### Modify

- `entry/src/main/ets/constants/ImportLimits.ets`: keep JSON limits unchanged; expose no PDF size through the JSON reader.
- `entry/src/main/ets/models/Question.ets`: mixed type labels, source pages, review state, and source images.
- `entry/src/main/ets/services/DatabaseService.ets`: schema version 2 migration and `question_image` table.
- `entry/src/main/ets/services/QuestionBankService.ets`: image-aware save/query/update/delete operations.
- `entry/src/main/ets/pages/ImportBankPage.ets`: separate JSON and PDF import actions.
- `entry/src/main/ets/pages/QuestionListPage.ets`: mixed-type and review-state display.
- `entry/src/main/ets/pages/QuestionDetailPage.ets`: source images, empty-answer copy, and edit route.
- `entry/src/main/ets/components/QuestionCard.ets`: review-state label.
- `entry/src/main/ets/utils/NavigationState.ets`: saved-question edit selection remains explicit.
- `entry/src/main/resources/base/profile/main_pages.json`: register four new pages.
- `entry/src/test/LocalUnit.test.ets`: validator, parser, type, and state tests.
- `entry/src/test/List.test.ets`: keep `localUnitTest()` as the Hypium suite entry.

## Verification commands used throughout

Set the environment in each new PowerShell process:

```powershell
$env:DEVECO_HOME = 'D:\Program Files\Huawei\DevEco Studio'
$env:DEVECO_SDK_HOME = 'D:\Program Files\Huawei\DevEco Studio\sdk'
$node = 'D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe'
$hvigor = 'D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js'
$checker = 'C:\Users\32773\.codex\skills\harmonyos-dev-skill\scripts\arkts-check.cjs'
```

ArkTS check after every `.ets` edit:

```powershell
& $node $checker --project 'C:\Users\32773\.codex\worktrees\fd0e\openHarmony\wrong_question_collection' --all
```

Expected: the JSON summary reports zero errors and zero warnings for project files.

Hypium local tests:

```powershell
& $node $hvigor test --mode module -p module=entry@default
```

Expected: all Hypium cases pass.

Debug HAP build:

```powershell
& $node $hvigor assembleHap --mode module -p product=default
```

Expected: `BUILD SUCCESSFUL` and `entry/build/default/outputs/default/entry-default-unsigned.hap` exists.

## Task 1: Typed PDF import domain and validation

**Files:**

- Create: `entry/src/main/ets/constants/PdfImportLimits.ets`
- Create: `entry/src/main/ets/models/QuestionImage.ets`
- Create: `entry/src/main/ets/models/PdfImportModels.ets`
- Create: `entry/src/main/ets/utils/PdfImportValidator.ets`
- Modify: `entry/src/main/ets/models/Question.ets`
- Modify: `entry/src/test/LocalUnit.test.ets`

- [ ] **Step 1: Write failing validator and model tests**

Add this Hypium block to `LocalUnit.test.ets` before creating the new files:

```typescript
describe('pdfImportValidation', () => {
  it('normalizes a pdf filename into a bank name', 0, () => {
    expect(PdfImportValidator.bankNameFromFileName('2026考研数学.pdf')).assertEqual('2026考研数学')
  })

  it('accepts exactly twenty selected pages', 0, () => {
    const result: PdfPageRangeValidation = PdfImportValidator.validatePageRange(5, 24, 166)
    expect(result.valid).assertTrue()
    expect(result.selectedPageCount).assertEqual(20)
  })

  it('rejects more than twenty selected pages', 0, () => {
    const result: PdfPageRangeValidation = PdfImportValidator.validatePageRange(5, 25, 166)
    expect(result.valid).assertFalse()
    expect(result.message).assertEqual('单次最多识别 20 页')
  })

  it('does not require an answer for completion', 0, () => {
    const question: Question = new Question('q1', 'b1', 'short_answer', '求极限',
      new Array<string>(), '', '', 7, 7, 'confirmed', new Array<QuestionImage>())
    expect(question.needsReview()).assertFalse()
    expect(question.getTypeLabel()).assertEqual('解答题')
  })
})
```

- [ ] **Step 2: Run the suite and verify the imports fail**

Run the Hypium command from “Verification commands used throughout”. Expected: compilation fails because `PdfImportValidator`, `PdfPageRangeValidation`, and `QuestionImage` do not exist.

- [ ] **Step 3: Add exact import limits and named models**

Create `PdfImportLimits.ets`:

```typescript
export class PdfImportLimits {
  static readonly MAX_FILE_BYTES: number = 200 * 1024 * 1024
  static readonly MAX_SELECTED_PAGES: number = 20
  static readonly MIN_PAGE_NUMBER: number = 1
  static readonly MAX_RENDER_LONG_EDGE: number = 2200
  static readonly MAX_SAVED_IMAGE_WIDTH: number = 1440
  static readonly JPEG_QUALITY: number = 88
  static readonly PAGE_TOP_MARGIN_RATIO: number = 0.04
  static readonly PAGE_BOTTOM_MARGIN_RATIO: number = 0.96
}
```

Create `QuestionImage.ets` with fields `id`, `questionId`, `pageNumber`, `imagePath`, and `sortOrder`. Create named classes in `PdfImportModels.ets` for `PdfFileSelection`, `PdfImportSettings`, `PdfPageRangeValidation`, `OcrLine`, `OcrPage`, `PageCrop`, `PdfQuestionDraft`, `PdfImportProgress`, and `PdfPageFailure`. Every class declares fields and initializes them in its constructor.

Use these public constructors:

```typescript
export class OcrLine {
  value: string
  pageNumber: number
  left: number
  top: number
  right: number
  bottom: number

  constructor(value: string, pageNumber: number, left: number, top: number,
    right: number, bottom: number)
}

export class OcrPage {
  pageNumber: number
  width: number
  height: number
  lines: Array<OcrLine>

  constructor(pageNumber: number, width: number, height: number, lines: Array<OcrLine>)
}

export class PageCrop {
  pageNumber: number
  left: number
  top: number
  right: number
  bottom: number

  constructor(pageNumber: number, left: number, top: number, right: number, bottom: number)
}

export class PdfQuestionDraft {
  localId: string
  type: string
  question: string
  options: Array<string>
  answer: string
  analysis: string
  sourcePageStart: number
  sourcePageEnd: number
  reviewState: string
  crops: Array<PageCrop>
  imagePaths: Array<string>

  constructor(localId: string, type: string, question: string, options: Array<string>,
    answer: string, analysis: string, sourcePageStart: number, sourcePageEnd: number,
    reviewState: string, crops: Array<PageCrop>, imagePaths: Array<string>)
}
```

- [ ] **Step 4: Extend `Question` without breaking existing call sites**

Add source metadata after the current constructor parameters with defaults:

```typescript
sourcePageStart: number
sourcePageEnd: number
reviewState: string
images: Array<QuestionImage>

constructor(id: string, bankId: string, type: string, question: string,
  options: Array<string>, answer: string, analysis: string, sourcePageStart: number = 0,
  sourcePageEnd: number = 0, reviewState: string = 'confirmed',
  images: Array<QuestionImage> = new Array<QuestionImage>())

needsReview(): boolean {
  return this.reviewState === 'needs_review'
}
```

`getTypeLabel()` returns `单选题`, `填空题`, `解答题`, or `待确认题型` for the four approved type strings.

- [ ] **Step 5: Implement the pure validator**

`PdfImportValidator.bankNameFromFileName` removes only the final case-insensitive `.pdf`, trims the result, and returns `未命名题库` when the remaining text is empty. `validateFileSize` accepts `1..MAX_FILE_BYTES`. `validatePageRange` checks positive one-based pages, start not greater than end, end not greater than total pages, and selected count not greater than 20; it returns the exact Chinese messages asserted by tests.

- [ ] **Step 6: Run ArkTS checks and Hypium tests**

Run `arkts-check` on the five changed `.ets` files and run Hypium. Expected: the four new tests pass and all existing JSON-import tests remain green.

- [ ] **Step 7: Commit**

```powershell
git add entry/src/main/ets/constants/PdfImportLimits.ets entry/src/main/ets/models/QuestionImage.ets entry/src/main/ets/models/PdfImportModels.ets entry/src/main/ets/models/Question.ets entry/src/main/ets/utils/PdfImportValidator.ets entry/src/test/LocalUnit.test.ets
git commit -m "feat: add typed PDF import domain"
```

## Task 2: OCR question parser with mixed-type and cross-page rules

**Files:**

- Create: `entry/src/main/ets/utils/PdfQuestionParser.ets`
- Modify: `entry/src/test/LocalUnit.test.ets`

- [ ] **Step 1: Add failing parser tests using coordinate-bearing OCR lines**

Add tests that construct lines explicitly:

```typescript
it('splits mixed question types and ignores page numbers', 0, () => {
  const lines: Array<OcrLine> = [
    new OcrLine('第4章 线性方程组', 47, 180, 20, 800, 60),
    new OcrLine('1. 方程组有无穷多解，则 a=', 47, 90, 180, 820, 220),
    new OcrLine('2. 设3维列向量组，充分必要条件为（ ）。', 47, 90, 270, 900, 315),
    new OcrLine('(A) k-l=0   (B) k+l=0', 47, 120, 330, 850, 370),
    new OcrLine('(C) k-l≠0   (D) k+l≠0', 47, 120, 380, 850, 420),
    new OcrLine('47', 47, 490, 1480, 520, 1510)
  ]
  const page: OcrPage = new OcrPage(47, 1000, 1530, lines)
  const drafts: Array<PdfQuestionDraft> = PdfQuestionParser.parse([page])
  expect(drafts.length).assertEqual(2)
  expect(drafts[0].type).assertEqual('fill_blank')
  expect(drafts[1].type).assertEqual('single_choice')
  expect(drafts[1].options.length).assertEqual(4)
})

it('appends next page prefix to the previous question', 0, () => {
  const lines: Array<OcrLine> = [
    new OcrLine('9. 证明数列收敛。', 7, 90, 1200, 850, 1240),
    new OcrLine('并求出它的极限。', 8, 90, 80, 850, 120),
    new OcrLine('10. 设函数连续，求极值。', 8, 90, 220, 850, 260)
  ]
  const firstPage: OcrPage = new OcrPage(7, 1000, 1530, [lines[0]])
  const secondPage: OcrPage = new OcrPage(8, 1000, 1530, [lines[1], lines[2]])
  const drafts: Array<PdfQuestionDraft> = PdfQuestionParser.parse([firstPage, secondPage])
  expect(drafts.length).assertEqual(2)
  expect(drafts[0].sourcePageStart).assertEqual(7)
  expect(drafts[0].sourcePageEnd).assertEqual(8)
  expect(drafts[0].crops.length).assertEqual(2)
})

it('keeps an unsplittable page as a review draft', 0, () => {
  const lines: Array<OcrLine> = [new OcrLine('只有公式且未识别到题号', 12, 80, 160, 900, 300)]
  const page: OcrPage = new OcrPage(12, 1000, 1530, lines)
  const drafts: Array<PdfQuestionDraft> = PdfQuestionParser.parse([page])
  expect(drafts.length).assertEqual(1)
  expect(drafts[0].reviewState).assertEqual('needs_review')
  expect(drafts[0].crops[0].top).assertEqual(0)
})
```

- [ ] **Step 2: Run Hypium and verify the missing parser failure**

Expected: compilation fails because `PdfQuestionParser.ets` does not exist.

- [ ] **Step 3: Implement deterministic line normalization and boundary detection**

`PdfQuestionParser.parse(pages)` copies and sorts pages by `pageNumber`, then sorts each page's lines by `top`, then `left`. It uses each page's own width and height, and drops lines entirely above `page.height * 0.04` or below `page.height * 0.96` when they are not part of a current question. A question start is a trimmed line that begins with one to four digits followed by `.`, `．`, `、`, or a space.

Use named private methods with these signatures:

```typescript
private static questionNumber(text: string): number
private static optionCode(text: string): string
private static classify(text: string, options: Array<string>): string
private static createFallback(pageNumber: number, pageWidth: number, pageHeight: number,
  lines: Array<OcrLine>): PdfQuestionDraft
```

`questionNumber` scans characters directly and returns `-1` when the prefix is invalid. `optionCode` recognizes `(A)`, `（A）`, `A.`, and `A．`. `classify` returns `single_choice` for two or more option codes, `fill_blank` when the joined text contains `____`, `______`, `（ ）`, or `( )`, and `short_answer` otherwise.

- [ ] **Step 4: Implement crops and cross-page continuation**

For each question start, close the previous crop at `current.top - 8`, never below its start. A question beginning on one page and receiving prefix lines on the next gets a second crop from `0` to the next question start. The final crop on a page ends at `pageHeight`; all crop coordinates are clamped to the page bounds.

Build question text from non-option lines. Build options from option markers in reading order. Keep `answer` and `analysis` as empty strings. Use `reviewState = 'confirmed'` whenever a valid boundary was found, regardless of answer presence; use `needs_review` only for whole-page fallback or unclassified empty text.

- [ ] **Step 5: Run ArkTS checks and Hypium tests**

Expected: the three parser tests pass, existing JSON parser behavior is unchanged, and no forbidden ArkTS syntax appears.

- [ ] **Step 6: Commit**

```powershell
git add entry/src/main/ets/utils/PdfQuestionParser.ets entry/src/test/LocalUnit.test.ets
git commit -m "feat: parse mixed PDF question layouts"
```

## Task 3: Schema version 2 and image-aware question persistence

**Files:**

- Modify: `entry/src/main/ets/services/DatabaseService.ets`
- Modify: `entry/src/main/ets/services/QuestionBankService.ets`
- Modify: `entry/src/test/PdfImportContracts.test.cjs`

- [ ] **Step 1: Write failing source-contract tests for the migration**

Create `PdfImportContracts.test.cjs` with Node’s test runner:

```javascript
const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')

test('schema version two contains question image storage', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/DatabaseService.ets', 'utf8')
  assert.match(source, /SCHEMA_VERSION:\s*number\s*=\s*2/)
  assert.match(source, /CREATE TABLE IF NOT EXISTS question_image/)
  assert.match(source, /source_page_start/)
  assert.match(source, /review_state/)
})
```

- [ ] **Step 2: Run the contract test and verify failure**

```powershell
node --test entry/src/test/PdfImportContracts.test.cjs
```

Expected: failure because the schema remains version 1.

- [ ] **Step 3: Add a transactional version-1-to-version-2 migration**

Set `SCHEMA_VERSION` to 2. Add `source_page_start`, `source_page_end`, and `review_state` to the version-2 `CREATE_QUESTION` statement. Add `CREATE_QUESTION_IMAGE` exactly as approved in the spec and an index on `question_image(question_id)`.

When `store.version === 1`, one transaction executes:

```sql
ALTER TABLE question ADD COLUMN source_page_start INTEGER NOT NULL DEFAULT 0
ALTER TABLE question ADD COLUMN source_page_end INTEGER NOT NULL DEFAULT 0
ALTER TABLE question ADD COLUMN review_state TEXT NOT NULL DEFAULT 'confirmed'
CREATE TABLE IF NOT EXISTS question_image (id TEXT PRIMARY KEY, question_id TEXT NOT NULL, page_number INTEGER NOT NULL, image_path TEXT NOT NULL, sort_order INTEGER NOT NULL)
CREATE INDEX IF NOT EXISTS idx_question_image_question_id ON question_image(question_id)
```

Commit, then set `store.version = 2`. Roll back on any statement failure and leave the original version unchanged.

- [ ] **Step 4: Extend bank save, query, update, and delete operations**

Update `QUESTION_COLUMNS` to include the three new fields. Add `QuestionImage` mapping and query images in `getQuestion` and `listQuestions`. Extend `saveImportedBank` so each question row and each associated image row are inserted in the same transaction.

Add this exact update API:

```typescript
static async updateQuestion(question: Question): Promise<void>
```

It updates only `type`, `content`, `options_json`, `answer`, `analysis`, and `review_state` using `WHERE id = ?`. It sets `review_state` to `confirmed` when non-empty question text is saved.

Change `deleteBank` to query associated image paths before the transaction, delete `question_image`, `wrong_question`, `question`, and `question_bank` rows in one transaction, and return `Array<string>` of paths only after commit:

```typescript
static async deleteBank(id: string): Promise<Array<string>>
```

- [ ] **Step 5: Update existing delete callers to consume the returned array**

For the intermediate commit, callers may ignore the returned local variable but must await the new signature. Do not delete files until `QuestionImageService` is introduced in Task 5.

- [ ] **Step 6: Run contract tests, ArkTS checks, and Hypium**

Expected: contract test passes, old sample data still maps with default source fields, and the existing app compiles against the new `deleteBank` signature.

- [ ] **Step 7: Commit**

```powershell
git add entry/src/main/ets/services/DatabaseService.ets entry/src/main/ets/services/QuestionBankService.ets entry/src/test/PdfImportContracts.test.cjs entry/src/main/ets/pages
git commit -m "feat: migrate storage for PDF source images"
```

## Task 4: PDF picker, streaming copy, metadata, and state handoff

**Files:**

- Create: `entry/src/main/ets/services/PdfImportService.ets`
- Create: `entry/src/main/ets/utils/PdfImportState.ets`
- Modify: `entry/src/test/PdfImportContracts.test.cjs`
- Modify: `entry/src/test/LocalUnit.test.ets`

- [ ] **Step 1: Add failing picker and state tests**

Add contract assertions for `PDF文件|.pdf`, `64 * 1024` chunking, `PdfDocument.isEncrypted`, `getPageCount`, and absence of whole-file `Uint8Array(fileInfo.size)`. Add this Hypium state test:

```typescript
it('copies PDF draft arrays at state boundaries', 0, () => {
  const state: PdfImportState = PdfImportState.shared()
  const drafts: Array<PdfQuestionDraft> = new Array<PdfQuestionDraft>()
  state.setDrafts(drafts)
  drafts.push(new PdfQuestionDraft('external', 'unclassified', '', new Array<string>(), '', '',
    0, 0, 'needs_review', new Array<PageCrop>(), new Array<string>()))
  expect(state.getDrafts().length).assertEqual(0)
})
```

- [ ] **Step 2: Verify tests fail before implementation**

Run Node contract tests and Hypium. Expected: missing service and state imports.

- [ ] **Step 3: Implement picker and streaming cache copy**

`PdfImportService.selectPdf(context)` uses `DocumentViewPicker` with `fileSuffixFilters = ['PDF文件|.pdf']` and one result. It opens the content URI read-only, reads `fs.stat(file.fd)`, validates size before copying, creates `context.cacheDir + '/pdf_import_' + Date.now().toString() + '.pdf'`, and copies 64 KiB chunks with `fs.read` and `fs.write`.

Do not allocate a buffer equal to the PDF size. Close source and destination descriptors in nested `finally` blocks. Delete the partial destination on failure.

After copying, instantiate `pdfService.PdfDocument`, reject `isEncrypted(tempPath)`, require `loadDocument(tempPath) === ParseResult.PARSE_SUCCESS`, read `getPageCount()`, release the document in `finally`, and return a `PdfFileSelection` whose one-based default range is page 1 to `min(20, pageCount)`.

Expose:

```typescript
static async selectPdf(context: Context): Promise<PdfFileSelection | null>
static async removeTemporaryPdf(path: string): Promise<void>
```

- [ ] **Step 4: Implement `PdfImportState` as a copying singleton**

Store a selection, settings, drafts, failures, and a `cancelRequested` boolean. `setDrafts` and `getDrafts` clone the array; every draft clone also copies options, crops, and image paths. `reset()` clears the whole session. `requestCancel()` changes only the cancellation flag.

- [ ] **Step 5: Run checks and tests**

Run `arkts-check` on both files, Node contract tests, and Hypium. Expected: all pass and the contract proves the implementation streams the sample-sized PDF.

- [ ] **Step 6: Commit**

```powershell
git add entry/src/main/ets/services/PdfImportService.ets entry/src/main/ets/utils/PdfImportState.ets entry/src/test/PdfImportContracts.test.cjs entry/src/test/LocalUnit.test.ets
git commit -m "feat: select and stage local PDF files"
```

## Task 5: On-device OCR, question crops, and sequential coordinator

**Files:**

- Create: `entry/src/main/ets/services/OnDeviceOcrService.ets`
- Create: `entry/src/main/ets/services/QuestionImageService.ets`
- Create: `entry/src/main/ets/services/PdfImportCoordinator.ets`
- Modify: `entry/src/test/PdfImportContracts.test.cjs`

- [ ] **Step 1: Add failing platform-contract assertions**

Assert that the new sources import `@kit.PDFKit`, `@kit.CoreVisionKit`, and `@kit.ImageKit`; call `textRecognition.init`, `recognizeText`, and `release`; call `getPagePixelMap`, `getAreaPixelMapWithOptions`, `PdfPage.release`, `PdfDocument.releaseDocument`, `PixelMap.release`, and `ImagePacker.release`; and contain no `@kit.NetworkKit` or `ohos.permission.INTERNET`.

- [ ] **Step 2: Verify the contract fails before adding services**

Run `node --test entry/src/test/PdfImportContracts.test.cjs`. Expected: missing source files.

- [ ] **Step 3: Implement typed OCR line conversion**

`OnDeviceOcrService.initialize()` awaits `textRecognition.init()` and throws when it returns false. `recognize(pixelMap, pageNumber)` calls `recognizeText` with a typed `VisionInfo` and direction detection enabled.

For every returned `TextLine`, derive bounds by iterating its `cornerPoints`; create an `OcrLine` only when `value.trim()` is non-empty and at least one point exists. `release()` awaits `textRecognition.release()` exactly once after a successful init.

- [ ] **Step 4: Implement direct PDF-area crop persistence**

`QuestionImageService.saveCrop(context, page, fullImageInfo, crop, taskId, draftId, order)` converts OCR pixel coordinates to PDF coordinates:

```typescript
const scaleX: number = page.getWidth() / fullImageInfo.size.width
const scaleY: number = page.getHeight() / fullImageInfo.size.height
matrix.x = crop.left * scaleX
matrix.y = page.getHeight() - crop.bottom * scaleY
matrix.width = (crop.right - crop.left) * scaleX
matrix.height = (crop.bottom - crop.top) * scaleY
matrix.rotate = 0
```

Render with `getAreaPixelMapWithOptions`; cap output width at 1440 and preserve aspect ratio. Encode JPEG quality 88 to `context.cacheDir + '/pdf_question_' + taskId + '_' + draftId + '_' + order.toString() + '.jpg'`. Always release the crop `PixelMap` and `ImagePacker` in `finally`.

Expose these exact APIs:

```typescript
static async commitImages(context: Context, bankId: string,
  paths: Array<string>): Promise<Array<string>>
static async deletePaths(context: Context, paths: Array<string>): Promise<void>
```

`commitImages` moves cache images into `context.filesDir + '/question_images/' + bankId` and returns final paths in the same order. `deletePaths` deletes only paths under the app’s `filesDir/question_images` or `cacheDir` roots.

- [ ] **Step 5: Implement the sequential coordinator and cancellation**

`PdfImportCoordinator.run(context, selection, settings, progressCallback, isCancelled)`:

1. Loads the staged PDF and initializes OCR.
2. Iterates from one-based `startPage` through `endPage`.
3. Before every page checks `isCancelled()`.
4. Obtains `PdfPage`, renders one full-page `PixelMap`, gets `ImageInfo`, OCRs it, and appends one `OcrPage` containing that page's dimensions and lines.
5. Records `PdfPageFailure` and continues when a page fails.
6. Releases page and full `PixelMap` in `finally`.
7. Parses all collected pages with `PdfQuestionParser.parse(pages)`.
8. Reopens each required page one at a time and saves every draft crop.
9. Releases OCR and document in outer `finally`.
10. Deletes all created cache crops when cancellation or a fatal error escapes.

The callback receives immutable `PdfImportProgress(stage, currentPage, totalPages, message)`. Stages are `opening`, `recognizing`, `cropping`, and `complete`.

- [ ] **Step 6: Run platform contracts and ArkTS checks**

Expected: all platform lifecycle calls are present, no network symbols are found, and ArkTS diagnostics are zero.

- [ ] **Step 7: Commit**

```powershell
git add entry/src/main/ets/services/OnDeviceOcrService.ets entry/src/main/ets/services/QuestionImageService.ets entry/src/main/ets/services/PdfImportCoordinator.ets entry/src/test/PdfImportContracts.test.cjs
git commit -m "feat: recognize and crop PDF questions on device"
```

## Task 6: PDF entry, setup, and progress pages

**Files:**

- Modify: `entry/src/main/ets/pages/ImportBankPage.ets`
- Create: `entry/src/main/ets/pages/PdfImportSetupPage.ets`
- Create: `entry/src/main/ets/pages/PdfImportProgressPage.ets`
- Modify: `entry/src/main/resources/base/profile/main_pages.json`
- Modify: `entry/src/test/PdfImportContracts.test.cjs`

- [ ] **Step 1: Add failing route and visible-copy contracts**

Assert that `main_pages.json` contains `pages/PdfImportSetupPage`, `pages/PdfImportProgressPage`, `pages/PdfImportReviewPage`, and `pages/EditQuestionPage`. Assert visible source strings include `导入 PDF`, `选择科目`, `起始页`, `结束页`, `单次最多识别 20 页`, `正在识别第`, and `取消识别`.

- [ ] **Step 2: Verify contract failure**

Run Node contract tests. Expected: missing routes and pages.

- [ ] **Step 3: Add a separate PDF action without changing JSON behavior**

Keep `startImport()` and the JSON button unchanged. Add `selectPdf()` to `ImportBankPage`: call `PdfImportService.selectPdf`, reset and populate `PdfImportState`, then navigate to `pages/PdfImportSetupPage`. Show file-selection and unsupported/encrypted errors in the existing visible error area.

- [ ] **Step 4: Build the setup form with explicit V1 state**

`PdfImportSetupPage` owns `@State bankName`, `subject`, `startPageText`, `endPageText`, and `errorMessage`. Render the selected filename and total pages. Use `TextInput` for bank name and page numbers, and a visible set of subject buttons for `数学`, `语文`, `英语`, `物理`, `化学`, `其他`; choosing `其他` reveals a subject `TextInput`.

On start, convert page strings with `Number.parseInt`, call `PdfImportValidator`, store `PdfImportSettings`, clear cancellation, and push `PdfImportProgressPage`. Invalid input updates visible `errorMessage`; it never starts the coordinator.

- [ ] **Step 5: Build progress and cancellation behavior**

Start the coordinator exactly once in `aboutToAppear`. Bind callback values into `@State progressMessage`, `currentPage`, and `totalPages`. The cancel button calls `PdfImportState.requestCancel()` and disables itself. On completion, store drafts and failures, delete the staged PDF, and replace the route with `PdfImportReviewPage`. On cancellation, delete staged PDF and cache crops, reset state, and return to the import page. Fatal errors show a retry/back state with the mapped Chinese message.

- [ ] **Step 6: Register routes and trace navigation**

The complete visible path is `ImportBankPage -> PdfImportSetupPage -> PdfImportProgressPage -> PdfImportReviewPage`. Keep the existing router pattern and `AppHeader` component. Do not introduce `Navigation` or mix decorator families.

- [ ] **Step 7: Run route contracts, ArkTS checks, and HAP build**

Expected: all routes resolve, required text is reachable, and build succeeds.

- [ ] **Step 8: Commit**

```powershell
git add entry/src/main/ets/pages/ImportBankPage.ets entry/src/main/ets/pages/PdfImportSetupPage.ets entry/src/main/ets/pages/PdfImportProgressPage.ets entry/src/main/resources/base/profile/main_pages.json entry/src/test/PdfImportContracts.test.cjs
git commit -m "feat: add PDF import setup and progress flow"
```

## Task 7: Review, edit, and transactional PDF-bank save

**Files:**

- Create: `entry/src/main/ets/pages/PdfImportReviewPage.ets`
- Modify: `entry/src/main/ets/services/QuestionBankService.ets`
- Modify: `entry/src/main/ets/services/QuestionImageService.ets`
- Modify: `entry/src/test/PdfImportContracts.test.cjs`

- [ ] **Step 1: Add failing review contracts**

Assert visible strings `识别结果`, `待确认`, `删除此题`, `保存题库`, `答案（选填）`, and `解析（选填）`. Assert `QuestionBankService` inserts `question_image` in the same transaction as bank and question rows.

- [ ] **Step 2: Verify contracts fail**

Expected: review page does not exist.

- [ ] **Step 3: Implement editable draft cards**

`PdfImportReviewPage` loads cloned drafts from `PdfImportState`. Each `ListItem` renders source images, type selection buttons, `TextArea` for question and analysis, one `TextInput` per option, and answer `TextInput`. Bind every field through explicit page methods such as `updateQuestionText(localId, value)` and replace the matching draft with a newly constructed draft so visible V1 state refreshes reliably.

Allow deleting any draft after an alert dialog whose buttons use `value`. Deletion immediately removes that draft’s cache images through `QuestionImageService.deletePaths(getContext(this), paths)`.

- [ ] **Step 4: Validate only essential content**

Before save, require at least one draft and non-empty question text for every non-fallback draft. Do not require answer or analysis. A fallback draft with an image and empty OCR text remains savable as `unclassified` with `reviewState = 'needs_review'`.

- [ ] **Step 5: Commit images and save one transaction**

Reserve a bank ID with `IdUtils.create('bank_')`, move cache images with `QuestionImageService.commitImages(getContext(this), bankId, paths)`, update drafts with the returned paths in the same order, convert drafts to `Question` and `QuestionImage` objects, and call a new exact API:

```typescript
static async savePdfBank(bank: QuestionBank, bankId: string): Promise<string>
```

If image commit fails, do not open the database transaction. If database save fails, delete the moved image directory. After success, reset `PdfImportState`, show `题库导入成功`, select the new bank in `NavigationState`, and replace the route with `QuestionListPage`.

- [ ] **Step 6: Run contracts, ArkTS checks, Hypium, and build**

Expected: blank answers save, fallback pages save with source images, and all existing JSON imports still use `saveImportedBank` unchanged.

- [ ] **Step 7: Commit**

```powershell
git add entry/src/main/ets/pages/PdfImportReviewPage.ets entry/src/main/ets/services/QuestionBankService.ets entry/src/main/ets/services/QuestionImageService.ets entry/src/test/PdfImportContracts.test.cjs
git commit -m "feat: review and save recognized PDF questions"
```

## Task 8: Source-image display, saved-question editing, and deletion cleanup

**Files:**

- Create: `entry/src/main/ets/components/QuestionSourceImages.ets`
- Create: `entry/src/main/ets/pages/EditQuestionPage.ets`
- Modify: `entry/src/main/ets/pages/QuestionDetailPage.ets`
- Modify: `entry/src/main/ets/pages/QuestionListPage.ets`
- Modify: `entry/src/main/ets/components/QuestionCard.ets`
- Modify: `entry/src/main/ets/services/QuestionBankService.ets`
- Modify: existing bank-deletion caller under `entry/src/main/ets/pages/BooksPage.ets`
- Modify: `entry/src/test/PdfImportContracts.test.cjs`

- [ ] **Step 1: Add failing detail/edit/cleanup contracts**

Assert visible strings `原题图片`, `未填写`, `编辑题目`, and `保存修改`. Assert `QuestionImageService.deletePaths` is called with the committed paths returned by `QuestionBankService.deleteBank`.

- [ ] **Step 2: Verify contracts fail**

Run Node contract tests. Expected: missing component, page, and cleanup call.

- [ ] **Step 3: Display source images with stable keys**

`QuestionSourceImages` receives `@Prop images: Array<QuestionImage>`. Render nothing for an empty array. Otherwise render the `原题图片` title and each local JPEG with `Image('file://' + image.imagePath)`, width `100%`, `objectFit(ImageFit.Contain)`, and a stable key of `image.id`.

- [ ] **Step 4: Update detail and list states**

Show source images before OCR question text. Display `未填写` for an empty answer and keep `暂无解析` for empty analysis. Add an `编辑题目` button that navigates to `EditQuestionPage` using the already selected question ID. Show `待确认` on list cards only when `question.needsReview()` is true.

- [ ] **Step 5: Implement saved-question editing**

`EditQuestionPage` loads the selected question, mirrors the review fields, and saves through `QuestionBankService.updateQuestion`. It does not modify or delete source images. Saving non-empty text sets review state to `confirmed`, shows `修改已保存`, and returns to detail; detail reloads in `onPageShow`.

- [ ] **Step 6: Complete bank image cleanup after database commit**

In `BooksPage`, await `QuestionBankService.deleteBank(bankId)`, receive committed image paths, then call `QuestionImageService.deletePaths(getContext(this), paths)`. A file cleanup failure does not restore deleted database rows; show `题库已删除，部分缓存稍后清理` and keep the UI consistent with the database.

- [ ] **Step 7: Run contracts, checks, tests, and build**

Expected: source images are reachable from a saved question, edits persist, JSON questions still render without an image section, and bank deletion removes image files after transaction commit.

- [ ] **Step 8: Commit**

```powershell
git add entry/src/main/ets/components/QuestionSourceImages.ets entry/src/main/ets/components/QuestionCard.ets entry/src/main/ets/pages/EditQuestionPage.ets entry/src/main/ets/pages/QuestionDetailPage.ets entry/src/main/ets/pages/QuestionListPage.ets entry/src/main/ets/pages/BooksPage.ets entry/src/main/ets/services/QuestionBankService.ets entry/src/test/PdfImportContracts.test.cjs
git commit -m "feat: view and edit imported PDF questions"
```

## Task 9: Failure paths, lifecycle cleanup, and regression verification

**Files:**

- Modify: `entry/src/main/ets/services/PdfImportService.ets`
- Modify: `entry/src/main/ets/services/PdfImportCoordinator.ets`
- Modify: `entry/src/main/ets/services/QuestionImageService.ets`
- Modify: `entry/src/main/ets/pages/PdfImportProgressPage.ets`
- Modify: `entry/src/main/ets/pages/PdfImportReviewPage.ets`
- Modify: `entry/src/test/LocalUnit.test.ets`
- Modify: `entry/src/test/PdfImportContracts.test.cjs`

- [ ] **Step 1: Add cancellation and partial-failure state tests**

Add Hypium cases proving `requestCancel` survives a progress update, `reset` clears staged paths, and a page failure can coexist with non-empty drafts. Add contract assertions that every platform object release appears in `finally` and no network permission appears in `module.json5`.

- [ ] **Step 2: Run tests and verify at least one new assertion fails**

Expected: lifecycle cleanup is incomplete until this task’s changes.

- [ ] **Step 3: Make cleanup idempotent and path-scoped**

Every cleanup method returns successfully when a file is already absent. Before deletion, resolve and compare the target with the explicit cache or question-image directory prefix; reject any target outside those roots. Review-page back navigation asks whether to discard and, when confirmed, deletes all unsaved cache crops and the staged PDF before resetting state.

- [ ] **Step 4: Map exact user-visible failures**

Use these messages:

- file over limit: `PDF 文件不能超过 200 MB`
- encrypted: `暂不支持加密 PDF`
- parse failure: `PDF 文件损坏或格式不受支持`
- OCR unavailable: `当前设备不支持端侧文字识别，请使用鸿蒙真机重试`
- one or more page failures: `部分页面识别失败，请检查标记页`
- storage failure: `本地空间不足或图片保存失败`
- fatal import failure: `PDF 导入失败，请重新选择文件`

- [ ] **Step 5: Run the full verification matrix**

```powershell
node --test entry/src/test/*.test.cjs
& $node $hvigor test --mode module -p module=entry@default
& $node $checker --project 'C:\Users\32773\.codex\worktrees\fd0e\openHarmony\wrong_question_collection' --all
& $node $hvigor assembleHap --mode module -p product=default
git diff --check
git status --short
```

Expected: all Node contracts pass; Hypium reports all cases passing; ArkTS checker reports zero project errors and warnings; build is successful; diff check is empty; status contains only intended feature changes before commit.

- [ ] **Step 6: Commit**

```powershell
git add entry/src/main/ets entry/src/main/resources/base/profile/main_pages.json entry/src/test
git commit -m "fix: harden on-device PDF import lifecycle"
```

## Task 10:真机 sample acceptance and target-directory synchronization

**Files:**

- Verify: `F:/BaiduNetdiskDownload/00.扫描资料/26张宇1000题/2026考研数学-张宇1000题数一（习题分册）.pdf`
- Verify: `entry/build/default/outputs/default/entry-default-unsigned.hap`
- Sync destination: `G:/code/openHarmony/wrong_question_collectionm1`

- [ ] **Step 1: Check for an attached HarmonyOS device**

```powershell
& 'D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' list targets
```

Expected: one device serial. If no serial is listed, record that all local checks passed and leave only the OCR effect acceptance pending; do not claim true-device OCR verification.

- [ ] **Step 2: Install and launch when a device is available**

```powershell
& 'D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' install 'C:\Users\32773\.codex\worktrees\fd0e\openHarmony\wrong_question_collection\entry\build\default\outputs\default\entry-default-unsigned.hap'
& 'D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' shell aa start -a EntryAbility -b com.example.wrong_question_collection
```

Expected: install and start succeed. If the unsigned HAP cannot install, build a signed debug HAP from DevEco Studio and repeat with that exact signed path.

- [ ] **Step 3: Run the approved sample checks on device**

Select the sample PDF, confirm total page count is 166, choose pages 47–50, select `数学`, and start recognition. Verify visible progress, cancellation on a second run, mixed question types, readable source-image crops, empty-answer save, cross-page image order, later editing, and image cleanup after deleting the bank.

- [ ] **Step 4: Synchronize tracked source files into the requested target**

Request filesystem approval because `G:/code/openHarmony/wrong_question_collectionm1` is outside the worktree. Overlay only files returned by `git ls-files`; do not copy `.hvigor`, `.cache`, `oh_modules`, `entry/build`, or worktree Git metadata. Preserve relative paths and create parent directories as needed.

- [ ] **Step 5: Verify synchronization by hashes**

For every tracked source path, compute SHA-256 in the worktree and target. Expected: zero missing files and zero mismatched hashes. Confirm the target remains an untracked directory under the main repository unless the user separately asks to commit it there.

- [ ] **Step 6: Final source commit and handoff**

```powershell
git status --short
git log --oneline -8
```

Expected: the source worktree is clean and the history contains the design, plan, and feature commits. Report the HAP path, test counts, device-verification status, target sync verification, and explicitly state that no cloud service or network permission was added.
