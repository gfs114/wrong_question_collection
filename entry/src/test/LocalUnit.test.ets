import { describe, it, expect } from '@ohos/hypium';
import { DateUtils } from '../main/ets/utils/DateUtils';
import { IdUtils } from '../main/ets/utils/IdUtils';
import { JsonParser } from '../main/ets/utils/JsonParser';
import { NavigationState } from '../main/ets/utils/NavigationState';
import { Utf8Utils } from '../main/ets/utils/Utf8Utils';
import { PdfImportLimits } from '../main/ets/constants/PdfImportLimits';
import { ImportErrorCode, ImportResult } from '../main/ets/models/ImportResult';
import {
  OcrLine,
  OcrPage,
  PageCrop,
  PdfFileSelection,
  PdfImportSettings,
  PdfPageFailure,
  PdfPageRangeValidation,
  PdfQuestionDraft
} from '../main/ets/models/PdfImportModels';
import { Question } from '../main/ets/models/Question';
import { QuestionImage } from '../main/ets/models/QuestionImage';
import { QuestionBank } from '../main/ets/models/QuestionBank';
import { PdfImportValidator } from '../main/ets/utils/PdfImportValidator';
import { PdfCropMath, PdfCropOutputSize } from '../main/ets/utils/PdfCropMath';
import { ImageWriteOwnership } from '../main/ets/utils/ImageWriteOwnership';
import { OcrLifecycleState, OcrRecognitionOperation } from '../main/ets/utils/OcrLifecycleState';
import { PdfQuestionParser } from '../main/ets/utils/PdfQuestionParser';
import { PdfSuccessfulPageParser } from '../main/ets/utils/PdfSuccessfulPageParser';
import { PdfImportState } from '../main/ets/utils/PdfImportState';
import { HomeDashboardMath, HomeDashboardSnapshot } from '../main/ets/models/HomeDashboard';
import { Statistics } from '../main/ets/models/Statistics';
import { QuestionBankSummary } from '../main/ets/models/QuestionBank';
import { WrongQuestionSummary } from '../main/ets/models/WrongQuestion';
import { AccountSessionTiming } from '../main/ets/models/AccountSession';
import { SyncOperationType, SyncOutboxPolicy, SyncSequence } from '../main/ets/models/SyncModels';

class ParserAssertions {
  static expectRejected(text: string): void {
    let rejected: boolean = false;
    try {
      JsonParser.parse(text);
    } catch (err) {
      rejected = true;
    }
    expect(rejected).assertTrue();
  }
}

class JsonSamples {
  static sampleQuestionBank(): string {
    return '{"bankName":"数学基础示例题库","subject":"数学","questions":[{"id":"1","type":"single_choice","question":"12 + 8 的结果是多少？","options":["A. 18","B. 19","C. 20","D. 22"],"answer":"C","analysis":"把 8 分成 3 和 5，12 + 3 = 15，再加 5 得 20。"},{"id":"2","type":"single_choice","question":"解方程 3x - 6 = 9，x 等于多少？","options":["A. 3","B. 5","C. 6","D. 7"],"answer":"B","analysis":"方程两边先加 6 得 3x = 15，再同时除以 3，得到 x = 5。"},{"id":"3","type":"single_choice","question":"一个长方形长 6 厘米、宽 4 厘米，它的面积是多少平方厘米？","options":["A. 10","B. 20","C. 22","D. 24"],"answer":"D","analysis":"长方形面积等于长乘宽，所以 6 × 4 = 24 平方厘米。"}]}';
  }

  static unknownValue(value: string): string {
    return '{"extra":' + value + ',"bankName":"数学示例","subject":"数学","questions":[{"id":"1","type":"single_choice","question":"题目","options":["A. 1","B. 2"],"answer":"A","analysis":""}]}';
  }

  static nestedUnknownValue(depth: number): string {
    let value: string = 'null';
    for (let level: number = 0; level < depth; level++) {
      value = '[' + value + ']';
    }
    return JsonSamples.unknownValue(value);
  }

  static bankWithOptionCount(optionCount: number): string {
    const options: Array<string> = new Array<string>();
    for (let index: number = 0; index < optionCount; index++) {
      options.push('"' + String.fromCharCode(65 + index) + '. 选项"');
    }
    return '{"bankName":"数学示例","subject":"数学","questions":[{"id":"1","type":"single_choice","question":"题目","options":[' +
      options.join(',') + '],"answer":"A","analysis":"解析"}]}';
  }

  static bankWithQuestionTextLength(length: number): string {
    let question: string = '';
    for (let index: number = 0; index < length; index++) {
      question += '题';
    }
    return '{"bankName":"数学示例","subject":"数学","questions":[{"id":"1","type":"single_choice","question":"' +
      question + '","options":["A. 1","B. 2"],"answer":"A","analysis":"解析"}]}';
  }

  static bankWithQuestionCount(questionCount: number): string {
    const questions: Array<string> = new Array<string>();
    for (let index: number = 0; index < questionCount; index++) {
      questions.push('{"id":"' + index.toString() +
        '","type":"single_choice","question":"题目","options":["A. 1","B. 2"],"answer":"A","analysis":"解析"}');
    }
    return '{"bankName":"数学示例","subject":"数学","questions":[' + questions.join(',') + ']}';
  }
}

export default function localUnitTest(): void {
  describe('syncOutboxPolicy', () => {
    it('keeps only the latest unsent state for an entity', 0, () => {
      expect(SyncOutboxPolicy.compactedOperation(
        SyncOperationType.UPSERT, SyncOperationType.UPSERT)).assertEqual(SyncOperationType.UPSERT)
      expect(SyncOutboxPolicy.compactedOperation(
        SyncOperationType.UPSERT, SyncOperationType.DELETE)).assertEqual(SyncOperationType.DELETE)
      expect(SyncOutboxPolicy.compactedOperation(
        SyncOperationType.DELETE, SyncOperationType.UPSERT)).assertEqual(SyncOperationType.UPSERT)
    })

    it('orders server sequences without losing integer precision', 0, () => {
      expect(SyncSequence.compare('9', '10')).assertEqual(-1)
      expect(SyncSequence.compare('18446744073709551614', '18446744073709551615')).assertEqual(-1)
      expect(SyncSequence.compare('0007', '7')).assertEqual(0)
    })
  })

  describe('accountSessionTiming', () => {
    it('derives access token expiry from the server lifetime', 0, () => {
      expect(AccountSessionTiming.expiresAt(1000, 60)).assertEqual(61000)
      expect(AccountSessionTiming.expiresAt(1000, -1)).assertEqual(1000)
    })

    it('refreshes inside the safety window', 0, () => {
      expect(AccountSessionTiming.isFresh(61000, 1000, 30000)).assertTrue()
      expect(AccountSessionTiming.isFresh(30000, 1000, 30000)).assertFalse()
    })
  })

  describe('homeDashboard', () => {
    it('returns zero mastery rate when no wrong questions exist', 0, () => {
      expect(HomeDashboardMath.masteryRate(0, 0)).assertEqual(0)
    })

    it('bounds mastery rate between zero and one hundred', 0, () => {
      expect(HomeDashboardMath.masteryRate(10, -2)).assertEqual(0)
      expect(HomeDashboardMath.masteryRate(10, 4)).assertEqual(40)
      expect(HomeDashboardMath.masteryRate(10, 20)).assertEqual(100)
    })

    it('copies and limits recent dashboard collections', 0, () => {
      const banks: Array<QuestionBankSummary> = [
        new QuestionBankSummary('b1', '书一', '数学', 10, 4, false),
        new QuestionBankSummary('b2', '书二', '数学', 9, 3, false),
        new QuestionBankSummary('b3', '书三', '数学', 8, 2, false),
        new QuestionBankSummary('b4', '书四', '数学', 7, 1, false)
      ]
      const wrong: Array<WrongQuestionSummary> = [
        new WrongQuestionSummary('w1', 'q1', 'b1', '数学', 4, false, '题一', '书一'),
        new WrongQuestionSummary('w2', 'q2', 'b1', '数学', 3, false, '题二', '书一'),
        new WrongQuestionSummary('w3', 'q3', 'b1', '数学', 2, true, '题三', '书一'),
        new WrongQuestionSummary('w4', 'q4', 'b1', '数学', 1, true, '题四', '书一')
      ]
      const snapshot: HomeDashboardSnapshot =
        new HomeDashboardSnapshot(new Statistics(4, 4, 2, 2), banks, wrong)
      banks.splice(0, banks.length)
      wrong.splice(0, wrong.length)
      expect(snapshot.recentBanks.length).assertEqual(3)
      expect(snapshot.recentWrongQuestions.length).assertEqual(3)
      expect(snapshot.statistics.pendingCount).assertEqual(2)
      expect(snapshot.masteryRate).assertEqual(50)
    })
  })

  describe('pdfImportValidation', () => {
    it('waits for active OCR recognition before allowing platform release', 0, async (): Promise<void> => {
      const lifecycle: OcrLifecycleState = new OcrLifecycleState()
      lifecycle.startInitialization()
      lifecycle.finishInitialization(true)
      const operation: OcrRecognitionOperation = lifecycle.beginRecognition()
      let releaseAllowed: boolean = false
      const releaseGate: Promise<void> = lifecycle.beginRelease()
      releaseGate.then((): void => {
        releaseAllowed = true
      })
      await Promise.resolve()
      expect(releaseAllowed).assertFalse()
      operation.complete()
      await releaseGate
      expect(releaseAllowed).assertTrue()
      lifecycle.finishRelease(true)
    })

    it('returns OCR lifecycle to ready after release failure and permits retry', 0, async (): Promise<void> => {
      const lifecycle: OcrLifecycleState = new OcrLifecycleState()
      lifecycle.startInitialization()
      lifecycle.finishInitialization(true)
      await lifecycle.beginRelease()
      lifecycle.finishRelease(false)
      expect(lifecycle.currentState()).assertEqual('ready')
      await lifecycle.beginRelease()
      lifecycle.finishRelease(true)
      expect(lifecycle.currentState()).assertEqual('idle')
    })

    it('requires initialization waiters to revalidate ready state', 0, () => {
      const lifecycle: OcrLifecycleState = new OcrLifecycleState()
      lifecycle.startInitialization()
      lifecycle.finishInitialization(false)
      let rejected: boolean = false
      try {
        lifecycle.requireReady()
      } catch (err) {
        rejected = true
      }
      expect(rejected).assertTrue()
      lifecycle.startInitialization()
      lifecycle.finishInitialization(true)
      lifecycle.requireReady()
      expect(lifecycle.currentState()).assertEqual('ready')
    })

    it('cleans only the temporary image when final target ownership was not acquired', 0, () => {
      const ownership: ImageWriteOwnership = new ImageWriteOwnership('/cache/temp.jpg', '/cache/final.jpg')
      ownership.markTemporaryCreated()
      expect(ownership.temporaryCleanupPath()).assertEqual('/cache/temp.jpg')
      expect(ownership.ownsFinalPath()).assertFalse()
      ownership.markMoved()
      expect(ownership.temporaryCleanupPath()).assertEqual('')
      expect(ownership.ownsFinalPath()).assertTrue()
      expect(ownership.resultPath()).assertEqual('/cache/final.jpg')
    })

    it('sizes wide PDF crops from OCR source pixels', 0, () => {
      const size: PdfCropOutputSize = PdfCropMath.calculate(2200, 1100)
      expect(size.width).assertEqual(1440)
      expect(size.height).assertEqual(720)
    })

    it('limits tall PDF crops while preserving source pixel ratio', 0, () => {
      const size: PdfCropOutputSize = PdfCropMath.calculate(100, 10000)
      expect(size.width).assertEqual(22)
      expect(size.height).assertEqual(2200)
    })

    it('does not enlarge small PDF crops and rejects invalid dimensions', 0, () => {
      const size: PdfCropOutputSize = PdfCropMath.calculate(500, 400)
      expect(size.width).assertEqual(500)
      expect(size.height).assertEqual(400)
      let rejected: boolean = false
      try {
        PdfCropMath.calculate(0, 400)
      } catch (err) {
        rejected = true
      }
      expect(rejected).assertTrue()
    })

    it('marks the first successful draft when the selected range starts with a failed page', 0, () => {
      const second: OcrPage = new OcrPage(2, 1000, 1530,
        [new OcrLine('2. 第二页题目', 2, 80, 180, 900, 230)])
      const third: OcrPage = new OcrPage(3, 1000, 1530,
        [new OcrLine('3. 第三页题目', 3, 80, 180, 900, 230)])
      const drafts: Array<PdfQuestionDraft> = PdfSuccessfulPageParser.parse([second, third], 1, 3)
      expect(drafts.length).assertEqual(2)
      expect(drafts[0].reviewState).assertEqual('needs_review')
      expect(drafts[1].reviewState).assertEqual('confirmed')
    })

    it('marks the last successful draft when the selected range ends with a failed page', 0, () => {
      const first: OcrPage = new OcrPage(1, 1000, 1530,
        [new OcrLine('1. 第一页题目', 1, 80, 180, 900, 230)])
      const second: OcrPage = new OcrPage(2, 1000, 1530,
        [new OcrLine('2. 第二页题目', 2, 80, 180, 900, 230)])
      const drafts: Array<PdfQuestionDraft> = PdfSuccessfulPageParser.parse([first, second], 1, 3)
      expect(drafts.length).assertEqual(2)
      expect(drafts[0].reviewState).assertEqual('confirmed')
      expect(drafts[1].reviewState).assertEqual('needs_review')
    })

    it('marks both sides of a failed page gap', 0, () => {
      const first: OcrPage = new OcrPage(1, 1000, 1530,
        [new OcrLine('1. 第一页题目', 1, 80, 180, 900, 230)])
      const third: OcrPage = new OcrPage(3, 1000, 1530,
        [new OcrLine('3. 第三页题目', 3, 80, 180, 900, 230)])
      const drafts: Array<PdfQuestionDraft> = PdfSuccessfulPageParser.parse([first, third], 1, 3)
      expect(drafts.length).assertEqual(2)
      expect(drafts[0].reviewState).assertEqual('needs_review')
      expect(drafts[1].reviewState).assertEqual('needs_review')
    })

    it('does not mark complete successful page ranges for review', 0, () => {
      const first: OcrPage = new OcrPage(1, 1000, 1530,
        [new OcrLine('1. 第一页题目', 1, 80, 180, 900, 230)])
      const second: OcrPage = new OcrPage(2, 1000, 1530,
        [new OcrLine('2. 第二页题目', 2, 80, 180, 900, 230)])
      const third: OcrPage = new OcrPage(3, 1000, 1530,
        [new OcrLine('3. 第三页题目', 3, 80, 180, 900, 230)])
      const drafts: Array<PdfQuestionDraft> = PdfSuccessfulPageParser.parse([first, second, third], 1, 3)
      expect(drafts.length).assertEqual(3)
      expect(drafts[0].reviewState).assertEqual('confirmed')
      expect(drafts[1].reviewState).assertEqual('confirmed')
      expect(drafts[2].reviewState).assertEqual('confirmed')
    })

    it('copies PDF draft arrays at state boundaries', 0, () => {
      const state: PdfImportState = PdfImportState.shared()
      state.reset()
      const drafts: Array<PdfQuestionDraft> = new Array<PdfQuestionDraft>()
      state.setDrafts(drafts)
      drafts.push(new PdfQuestionDraft('external', 'unclassified', '', new Array<string>(), '', '',
        0, 0, 'needs_review', new Array<PageCrop>(), new Array<string>()))
      expect(state.getDrafts().length).assertEqual(0)
    })

    it('keeps a cancellation request after progress state updates', 0, () => {
      const state: PdfImportState = PdfImportState.shared()
      state.reset()
      state.requestCancel()
      state.setDrafts([new PdfQuestionDraft('draft-progress', 'short_answer', '题目', new Array<string>(), '', '',
        2, 2, 'confirmed', new Array<PageCrop>(), new Array<string>())])
      state.setFailures([new PdfPageFailure(3, '第 3 页识别失败')])
      expect(state.isCancelRequested()).assertTrue()
      state.reset()
    })

    it('reset clears the staged PDF selection and all session paths', 0, () => {
      const state: PdfImportState = PdfImportState.shared()
      state.reset()
      state.setSelection(new PdfFileSelection('/cache/staged_pdf_123.pdf', '试卷.pdf', 1024, 5, 1, 5))
      state.setDrafts([new PdfQuestionDraft('draft-reset', 'unclassified', '', new Array<string>(), '', '',
        1, 1, 'needs_review', new Array<PageCrop>(), ['/cache/pdf_question_reset.jpg'])])
      state.reset()
      expect(state.getSelection() === null).assertTrue()
      expect(state.getDrafts().length).assertEqual(0)
      expect(state.getFailures().length).assertEqual(0)
    })

    it('keeps successful drafts when one selected PDF page fails', 0, () => {
      const state: PdfImportState = PdfImportState.shared()
      state.reset()
      state.setDrafts([new PdfQuestionDraft('draft-partial', 'short_answer', '成功识别的题目',
        new Array<string>(), '', '', 4, 4, 'needs_review', new Array<PageCrop>(),
        ['/cache/pdf_question_partial.jpg'])])
      state.setFailures([new PdfPageFailure(5, '第 5 页识别失败')])
      expect(state.getDrafts().length).assertEqual(1)
      expect(state.getFailures().length).assertEqual(1)
      expect(state.getFailures()[0].pageNumber).assertEqual(5)
      state.reset()
    })

    it('deep copies PDF draft values on both state boundaries', 0, () => {
      const state: PdfImportState = PdfImportState.shared()
      state.reset()
      const options: Array<string> = ['A. 原选项']
      const crops: Array<PageCrop> = [new PageCrop(3, 10, 20, 30, 40)]
      const imagePaths: Array<string> = ['/images/original.jpg']
      const draft: PdfQuestionDraft = new PdfQuestionDraft('draft-1', 'single_choice', '原题目', options, 'A',
        '原解析', 3, 3, 'needs_review', crops, imagePaths)
      state.setDrafts([draft])
      options[0] = 'A. 外部修改'
      crops[0].top = 999
      imagePaths[0] = '/images/external.jpg'
      draft.question = '外部题目'
      const firstRead: Array<PdfQuestionDraft> = state.getDrafts()
      expect(firstRead[0].options[0]).assertEqual('A. 原选项')
      expect(firstRead[0].crops[0].top).assertEqual(20)
      expect(firstRead[0].imagePaths[0]).assertEqual('/images/original.jpg')
      expect(firstRead[0].question).assertEqual('原题目')
      firstRead[0].options[0] = 'A. 返回值修改'
      firstRead[0].crops[0].top = 888
      firstRead[0].imagePaths[0] = '/images/returned.jpg'
      firstRead[0].question = '返回题目'
      firstRead.push(new PdfQuestionDraft('returned', 'unclassified', '', new Array<string>(), '', '',
        0, 0, 'needs_review', new Array<PageCrop>(), new Array<string>()))
      const secondRead: Array<PdfQuestionDraft> = state.getDrafts()
      expect(secondRead.length).assertEqual(1)
      expect(secondRead[0].options[0]).assertEqual('A. 原选项')
      expect(secondRead[0].crops[0].top).assertEqual(20)
      expect(secondRead[0].imagePaths[0]).assertEqual('/images/original.jpg')
      expect(secondRead[0].question).assertEqual('原题目')
    })

    it('isolates PDF session metadata failures and cancellation state', 0, () => {
      const state: PdfImportState = PdfImportState.shared()
      expect(PdfImportState.shared() === state).assertTrue()
      state.reset()
      const selection: PdfFileSelection = new PdfFileSelection('/cache/staged_pdf_1.pdf', '试卷.pdf', 128, 30,
        1, 20)
      const settings: PdfImportSettings = new PdfImportSettings('试卷', '数学', 2, 18)
      const failures: Array<PdfPageFailure> = [new PdfPageFailure(4, '识别失败')]
      state.setSelection(selection)
      state.setSettings(settings)
      state.setFailures(failures)
      selection.fileName = '外部.pdf'
      settings.subject = '外部科目'
      failures[0].message = '外部失败'
      const storedSelection: PdfFileSelection | null = state.getSelection()
      const storedSettings: PdfImportSettings | null = state.getSettings()
      const storedFailures: Array<PdfPageFailure> = state.getFailures()
      if (storedSelection !== null) {
        expect(storedSelection.fileName).assertEqual('试卷.pdf')
        storedSelection.fileName = '返回值.pdf'
      } else {
        expect(false).assertTrue()
      }
      if (storedSettings !== null) {
        expect(storedSettings.subject).assertEqual('数学')
        storedSettings.subject = '返回值科目'
      } else {
        expect(false).assertTrue()
      }
      expect(storedFailures[0].message).assertEqual('识别失败')
      storedFailures[0].message = '返回值失败'
      const secondSelection: PdfFileSelection | null = state.getSelection()
      const secondSettings: PdfImportSettings | null = state.getSettings()
      if (secondSelection !== null) {
        expect(secondSelection.fileName).assertEqual('试卷.pdf')
      } else {
        expect(false).assertTrue()
      }
      if (secondSettings !== null) {
        expect(secondSettings.subject).assertEqual('数学')
      } else {
        expect(false).assertTrue()
      }
      expect(state.getFailures()[0].message).assertEqual('识别失败')
      state.requestCancel()
      expect(state.isCancelRequested()).assertTrue()
      expect(state.getDrafts().length).assertEqual(0)
      state.clearCancelRequest()
      expect(state.isCancelRequested()).assertFalse()
      state.requestCancel()
      state.reset()
      expect(state.isCancelRequested()).assertFalse()
      expect(state.getSelection() === null).assertTrue()
      expect(state.getSettings() === null).assertTrue()
      expect(state.getFailures().length).assertEqual(0)
    })

    it('splits mixed question types and ignores page numbers', 0, () => {
      const lines: Array<OcrLine> = [
        new OcrLine('第4章 线性方程组', 47, 180, 20, 800, 60),
        new OcrLine('1. 方程组有无穷多解，则 a=____', 47, 90, 180, 820, 220),
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
      expect(drafts[1].options[0].indexOf('(A)')).assertEqual(0)
      expect(drafts[1].options[1].indexOf('(B)')).assertEqual(0)
      expect(drafts[1].options[2].indexOf('(C)')).assertEqual(0)
      expect(drafts[1].options[3].indexOf('(D)')).assertEqual(0)
      expect(drafts[1].question.indexOf('47')).assertEqual(-1)
    })

    it('keeps inline letter punctuation as question text', 0, () => {
      const text: string = '1. 设函数 A.表示定义域，B.表示值域，求关系。'
      const lines: Array<OcrLine> = [new OcrLine(text, 6, 80, 180, 900, 240)]
      const page: OcrPage = new OcrPage(6, 1000, 1530, lines)
      const drafts: Array<PdfQuestionDraft> = PdfQuestionParser.parse([page])
      expect(drafts.length).assertEqual(1)
      expect(drafts[0].options.length).assertEqual(0)
      expect(drafts[0].type).assertEqual('short_answer')
      expect(drafts[0].question).assertEqual(text)
    })

    it('parses inline bracketed options after a question prefix', 0, () => {
      const lines: Array<OcrLine> = [
        new OcrLine('1. 以下正确的是：(A)甲 (B)乙', 6, 80, 280, 900, 340)
      ]
      const page: OcrPage = new OcrPage(6, 1000, 1530, lines)
      const drafts: Array<PdfQuestionDraft> = PdfQuestionParser.parse([page])
      expect(drafts.length).assertEqual(1)
      expect(drafts[0].question).assertEqual('1. 以下正确的是：')
      expect(drafts[0].options.length).assertEqual(2)
      expect(drafts[0].options[0]).assertEqual('(A)甲')
      expect(drafts[0].options[1]).assertEqual('(B)乙')
      expect(drafts[0].type).assertEqual('single_choice')
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
      expect(drafts[0].question.indexOf('并求出它的极限') >= 0).assertTrue()
    })

    it('keeps leading continuation content as a review draft', 0, () => {
      const lines: Array<OcrLine> = [
        new OcrLine('上一页题目续文/公式说明', 5, 80, 80, 900, 130),
        new OcrLine('10. 设函数连续，求极值。', 5, 90, 220, 850, 260)
      ]
      const page: OcrPage = new OcrPage(5, 1000, 1530, lines)
      const drafts: Array<PdfQuestionDraft> = PdfQuestionParser.parse([page])
      expect(drafts.length).assertEqual(2)
      expect(drafts[0].reviewState).assertEqual('needs_review')
      expect(drafts[0].question.indexOf('上一页题目续文') >= 0).assertTrue()
      expect(drafts[0].crops.length).assertEqual(1)
      expect(drafts[0].crops[0].pageNumber).assertEqual(5)
      expect(drafts[0].crops[0].top).assertEqual(0)
      expect(drafts[0].crops[0].bottom).assertEqual(212)
      expect(drafts[0].crops[0].bottom > drafts[0].crops[0].top).assertTrue()
      expect(drafts[0].localId === drafts[1].localId).assertFalse()
    })

    it('keeps a cross page crop when the next page begins with a new question', 0, () => {
      const firstPage: OcrPage = new OcrPage(7, 1000, 1530,
        [new OcrLine('9. 证明数列收敛。', 7, 90, 1200, 850, 1240)])
      const secondPage: OcrPage = new OcrPage(8, 1000, 1530,
        [new OcrLine('10. 设函数连续，求极值。', 8, 90, 220, 850, 260)])
      const drafts: Array<PdfQuestionDraft> = PdfQuestionParser.parse([firstPage, secondPage])
      expect(drafts.length).assertEqual(2)
      expect(drafts[0].crops.length).assertEqual(2)
      expect(drafts[0].crops[1].pageNumber).assertEqual(8)
      expect(drafts[0].crops[1].top).assertEqual(0)
      expect(drafts[0].crops[1].bottom).assertEqual(212)
      expect(drafts[0].sourcePageEnd).assertEqual(8)
    })

    it('keeps trailing equals questions as short answers', 0, () => {
      const lines: Array<OcrLine> = [new OcrLine('1. 计算 1+1=', 3, 80, 180, 900, 230)]
      const page: OcrPage = new OcrPage(3, 1000, 1530, lines)
      const drafts: Array<PdfQuestionDraft> = PdfQuestionParser.parse([page])
      expect(drafts.length).assertEqual(1)
      expect(drafts[0].type).assertEqual('short_answer')
    })

    it('keeps every crop positive when question tops overlap', 0, () => {
      const lines: Array<OcrLine> = [
        new OcrLine('1. 第一题', 20, 80, 200, 850, 240),
        new OcrLine('2. 第二题', 20, 90, 200, 850, 250)
      ]
      const page: OcrPage = new OcrPage(20, 1000, 1530, lines)
      const drafts: Array<PdfQuestionDraft> = PdfQuestionParser.parse([page])
      expect(drafts.length).assertEqual(2)
      for (let draftIndex: number = 0; draftIndex < drafts.length; draftIndex++) {
        for (let cropIndex: number = 0; cropIndex < drafts[draftIndex].crops.length; cropIndex++) {
          expect(drafts[draftIndex].crops[cropIndex].right > drafts[draftIndex].crops[cropIndex].left).assertTrue()
          expect(drafts[draftIndex].crops[cropIndex].bottom > drafts[draftIndex].crops[cropIndex].top).assertTrue()
        }
      }
    })

    it('omits crops for pages without positive dimensions', 0, () => {
      const zeroWidth: OcrPage = new OcrPage(21, 0, 1530,
        [new OcrLine('未识别公式', 21, 0, 180, 0, 240)])
      const zeroHeight: OcrPage = new OcrPage(22, 1000, 0,
        [new OcrLine('未识别公式', 22, 80, 0, 900, 0)])
      const drafts: Array<PdfQuestionDraft> = PdfQuestionParser.parse([zeroHeight, zeroWidth])
      expect(drafts.length).assertEqual(2)
      expect(drafts[0].reviewState).assertEqual('needs_review')
      expect(drafts[1].reviewState).assertEqual('needs_review')
      expect(drafts[0].crops.length).assertEqual(0)
      expect(drafts[1].crops.length).assertEqual(0)
    })

    it('does not reorder input page or line arrays', 0, () => {
      const lower: OcrLine = new OcrLine('1. 较低的题', 31, 80, 300, 900, 350)
      const upper: OcrLine = new OcrLine('未分类前缀', 31, 80, 100, 900, 150)
      const laterPage: OcrPage = new OcrPage(31, 1000, 1530, [lower, upper])
      const earlierPage: OcrPage = new OcrPage(30, 1000, 1530,
        [new OcrLine('未分类内容', 30, 80, 180, 900, 230)])
      const pages: Array<OcrPage> = [laterPage, earlierPage]
      PdfQuestionParser.parse(pages)
      expect(pages[0].pageNumber).assertEqual(31)
      expect(pages[1].pageNumber).assertEqual(30)
      expect(laterPage.lines[0].top).assertEqual(300)
      expect(laterPage.lines[1].top).assertEqual(100)
    })

    it('keeps an unsplittable page as a review draft', 0, () => {
      const lines: Array<OcrLine> = [new OcrLine('只有公式且未识别到题号', 12, 80, 160, 900, 300)]
      const page: OcrPage = new OcrPage(12, 1000, 1530, lines)
      const drafts: Array<PdfQuestionDraft> = PdfQuestionParser.parse([page])
      expect(drafts.length).assertEqual(1)
      expect(drafts[0].reviewState).assertEqual('needs_review')
      expect(drafts[0].crops[0].top).assertEqual(0)
    })

    it('normalizes a pdf filename into a bank name', 0, () => {
      expect(PdfImportValidator.bankNameFromFileName('2026考研数学.pdf')).assertEqual('2026考研数学')
    })

    it('removes only the final case insensitive pdf suffix and trims whitespace', 0, () => {
      expect(PdfImportValidator.bankNameFromFileName('  a.pdf.PDF  ')).assertEqual('a.pdf')
    })

    it('falls back when removing the pdf suffix leaves no bank name', 0, () => {
      expect(PdfImportValidator.bankNameFromFileName('  .pdf  ')).assertEqual('未命名题库')
      expect(PdfImportValidator.bankNameFromFileName('   ')).assertEqual('未命名题库')
    })

    it('accepts only file sizes within the configured byte limit', 0, () => {
      expect(PdfImportValidator.validateFileSize(1)).assertTrue()
      expect(PdfImportValidator.validateFileSize(PdfImportLimits.MAX_FILE_BYTES)).assertTrue()
      expect(PdfImportValidator.validateFileSize(0)).assertFalse()
      expect(PdfImportValidator.validateFileSize(PdfImportLimits.MAX_FILE_BYTES + 1)).assertFalse()
      expect(PdfImportValidator.validateFileSize(1.5)).assertFalse()
      expect(PdfImportValidator.validateFileSize(Number.NaN)).assertFalse()
      expect(PdfImportValidator.validateFileSize(Number.POSITIVE_INFINITY)).assertFalse()
      expect(PdfImportValidator.validateFileSize(Number.NEGATIVE_INFINITY)).assertFalse()
    })

    it('accepts exactly twenty selected pages', 0, () => {
      const result: PdfPageRangeValidation = PdfImportValidator.validatePageRange(5, 24, 166)
      expect(result.valid).assertTrue()
      expect(result.selectedPageCount).assertEqual(20)
    })

    it('rejects more than twenty selected pages', 0, () => {
      const result: PdfPageRangeValidation = PdfImportValidator.validatePageRange(5, 25, 166)
      expect(result.valid).assertFalse()
      expect(result.selectedPageCount).assertEqual(21)
      expect(result.message).assertEqual('单次最多识别 20 页')
    })

    it('rejects page ranges outside one based positive integers', 0, () => {
      const invalidStart: PdfPageRangeValidation = PdfImportValidator.validatePageRange(0, 1, 10)
      const invalidEnd: PdfPageRangeValidation = PdfImportValidator.validatePageRange(1, 0, 10)
      const invalidTotal: PdfPageRangeValidation = PdfImportValidator.validatePageRange(1, 1, 0)
      expect(invalidStart.valid).assertFalse()
      expect(invalidEnd.valid).assertFalse()
      expect(invalidTotal.valid).assertFalse()
      expect(invalidStart.selectedPageCount).assertEqual(0)
      expect(invalidStart.message).assertEqual('页码必须是从 1 开始的正整数')
    })

    it('rejects a page range whose start is after its end', 0, () => {
      const result: PdfPageRangeValidation = PdfImportValidator.validatePageRange(8, 7, 10)
      expect(result.valid).assertFalse()
      expect(result.selectedPageCount).assertEqual(0)
      expect(result.message).assertEqual('起始页不能大于结束页')
    })

    it('rejects a page range whose end exceeds the document', 0, () => {
      const result: PdfPageRangeValidation = PdfImportValidator.validatePageRange(8, 11, 10)
      expect(result.valid).assertFalse()
      expect(result.selectedPageCount).assertEqual(4)
      expect(result.message).assertEqual('结束页不能超过 PDF 总页数')
    })

    it('rejects decimal and non finite page values', 0, () => {
      const decimal: PdfPageRangeValidation = PdfImportValidator.validatePageRange(1.5, 2, 10)
      const nan: PdfPageRangeValidation = PdfImportValidator.validatePageRange(Number.NaN, 2, 10)
      const positiveInfinity: PdfPageRangeValidation =
        PdfImportValidator.validatePageRange(1, Number.POSITIVE_INFINITY, 10)
      const negativeInfinity: PdfPageRangeValidation =
        PdfImportValidator.validatePageRange(1, 2, Number.NEGATIVE_INFINITY)
      expect(decimal.valid).assertFalse()
      expect(nan.valid).assertFalse()
      expect(positiveInfinity.valid).assertFalse()
      expect(negativeInfinity.valid).assertFalse()
      expect(decimal.selectedPageCount).assertEqual(0)
      expect(nan.message).assertEqual('页码必须是从 1 开始的正整数')
    })

    it('does not require an answer for completion', 0, () => {
      const question: Question = new Question('q1', 'b1', 'short_answer', '求极限',
        new Array<string>(), '', '', 7, 7, 'confirmed', new Array<QuestionImage>())
      expect(question.needsReview()).assertFalse()
      expect(question.getTypeLabel()).assertEqual('解答题')
    })

    it('keeps the seven argument question constructor compatible', 0, () => {
      const question: Question = new Question('q1', 'b1', 'single_choice', '题目',
        new Array<string>(), 'A', '解析')
      expect(question.sourcePageStart).assertEqual(0)
      expect(question.sourcePageEnd).assertEqual(0)
      expect(question.reviewState).assertEqual('confirmed')
      expect(question.needsReview()).assertFalse()
      expect(question.images.length).assertEqual(0)
    })

    it('creates an independent default image array for each question', 0, () => {
      const first: Question = new Question('q1', 'b1', 'single_choice', '第一题',
        new Array<string>(), 'A', '解析')
      const second: Question = new Question('q2', 'b1', 'single_choice', '第二题',
        new Array<string>(), 'A', '解析')
      first.images.push(new QuestionImage('image1', 'q1', 1, '/images/q1.jpg', 0))
      expect(first.images.length).assertEqual(1)
      expect(second.images.length).assertEqual(0)
    })

    it('marks only needs review questions for review', 0, () => {
      const question: Question = new Question('q1', 'b1', 'unclassified', '题目',
        new Array<string>(), '', '', 1, 1, 'needs_review', new Array<QuestionImage>())
      expect(question.needsReview()).assertTrue()
    })
  })

  describe('domainUtilities', () => {
    it('formats dates with zero padding', 0, () => {
      const localMidnight: number = new Date(2026, 0, 2, 0, 0, 0, 0).getTime();
      expect(DateUtils.formatDate(localMidnight)).assertEqual('2026-01-02');
      expect(DateUtils.formatDateTime(localMidnight)).assertEqual('2026-01-02 00:00');
    });

    it('creates unique prefixed ids', 0, () => {
      const first: string = IdUtils.create('bank_');
      const second: string = IdUtils.create('bank_');
      expect(first.startsWith('bank_')).assertTrue();
      expect(second.startsWith('bank_')).assertTrue();
      expect(first === second).assertFalse();
    });

    it('moves selected question within ordered bounds', 0, () => {
      const state: NavigationState = NavigationState.shared();
      const sourceIds: Array<string> = ['q1', 'q2', 'q3'];
      state.selectQuestion('q2', 'bank1', sourceIds, 1);
      sourceIds.splice(2, 1, 'source-mutated');
      const returnedIds: Array<string> = state.orderedIds;
      returnedIds.splice(2, 1, 'returned-mutated');
      state.moveQuestion(1);
      expect(state.selectedQuestionId).assertEqual('q3');
      expect(state.questionIndex).assertEqual(2);
      state.moveQuestion(1);
      expect(state.selectedQuestionId).assertEqual('q3');
      state.moveQuestion(-2);
      expect(state.selectedQuestionId).assertEqual('q1');
      expect(state.questionIndex).assertEqual(0);
    });
  });

  describe('jsonParser', () => {
    it('parses packaged sample question bank contract', 0, () => {
      const bank: QuestionBank = JsonParser.parse(JsonSamples.sampleQuestionBank());
      expect(bank.bankName).assertEqual('数学基础示例题库');
      expect(bank.subject).assertEqual('数学');
      expect(bank.questions.length).assertEqual(3);
      for (const question of bank.questions) {
        expect(question.type).assertEqual('single_choice');
        expect(question.options.length).assertEqual(4);
        expect(question.answer.length).assertEqual(1);
        expect(question.analysis.length > 0).assertTrue();
      }
    });

    it('parses valid single choice bank', 0, () => {
      const text: string = '{"bankName":"数学示例","subject":"数学","questions":[{"id":"1","type":"single_choice","question":"1 + 1 = ?","options":["A. 1","B. 2"],"answer":" b ","analysis":"1 + 1 = 2。"}]}';
      const bank: QuestionBank = JsonParser.parse(text);
      expect(bank.id).assertEqual('');
      expect(bank.bankName).assertEqual('数学示例');
      expect(bank.subject).assertEqual('数学');
      expect(bank.questionCount).assertEqual(1);
      expect(bank.questions.length).assertEqual(1);
      expect(bank.questions[0].id).assertEqual('1');
      expect(bank.questions[0].bankId).assertEqual('');
      expect(bank.questions[0].answer).assertEqual('B');
    });

    it('accepts empty analysis string', 0, () => {
      const text: string = '{"bankName":"数学示例","subject":"数学","questions":[{"id":"1","type":"single_choice","question":"1 + 1 = ?","options":["A. 1","B. 2"],"answer":"B","analysis":""}]}';
      const bank: QuestionBank = JsonParser.parse(text);
      expect(bank.questions[0].analysis).assertEqual('');
    });

    it('rejects missing analysis field', 0, () => {
      const text: string = '{"bankName":"数学示例","subject":"数学","questions":[{"id":"1","type":"single_choice","question":"1 + 1 = ?","options":["A. 1","B. 2"],"answer":"B"}]}';
      ParserAssertions.expectRejected(text);
    });

    it('rejects answer without matching option', 0, () => {
      const text: string = '{"bankName":"数学示例","subject":"数学","questions":[{"id":"1","type":"single_choice","question":"1 + 1 = ?","options":["A. 1","B. 2"],"answer":"C","analysis":"解析"}]}';
      ParserAssertions.expectRejected(text);
    });

    it('rejects malformed JSON', 0, () => {
      const text: string = '{"bankName":"数学示例","subject":"数学","questions":[{"id":"1","type":"single_choice","question":"题目","options":["A. 1","B. 2"],"answer":"A","analysis":"解析"}]';
      ParserAssertions.expectRejected(text);
    });

    it('rejects trailing non whitespace content', 0, () => {
      const text: string = '{"bankName":"数学示例","subject":"数学","questions":[{"id":"1","type":"single_choice","question":"题目","options":["A. 1","B. 2"],"answer":"A","analysis":"解析"}]} trailing';
      ParserAssertions.expectRejected(text);
    });

    it('rejects duplicate question ids', 0, () => {
      const text: string = '{"bankName":"数学示例","subject":"数学","questions":[{"id":"1","type":"single_choice","question":"第一题","options":["A. 1","B. 2"],"answer":"A","analysis":"解析"},{"id":"1","type":"single_choice","question":"第二题","options":["A. 1","B. 2"],"answer":"B","analysis":"解析"}]}';
      ParserAssertions.expectRejected(text);
    });

    it('rejects unsupported question type', 0, () => {
      const text: string = '{"bankName":"数学示例","subject":"数学","questions":[{"id":"1","type":"multiple_choice","question":"1 + 1 = ?","options":["A. 1","B. 2"],"answer":"B","analysis":"解析"}]}';
      ParserAssertions.expectRejected(text);
    });

    it('ignores extra nested fields', 0, () => {
      const text: string = '{"metadata":{"enabled":true,"ratio":-12.5e+2,"items":[null,false,{"value":"ignored"}]},"bankName":"数学示例","subject":"数学","questions":[{"id":"1","type":"single_choice","question":"1 + 1 = ?","options":["A. 1","B. 2"],"answer":"B","analysis":"解析","extra":[1,{"nested":[true,null]}]}]}';
      const bank: QuestionBank = JsonParser.parse(text);
      expect(bank.questions.length).assertEqual(1);
      expect(bank.questions[0].question).assertEqual('1 + 1 = ?');
    });

    it('accepts unknown values at nesting limit', 0, () => {
      const bank: QuestionBank = JsonParser.parse(JsonSamples.nestedUnknownValue(64));
      expect(bank.questions.length).assertEqual(1);
    });

    it('rejects unknown values above nesting limit', 0, () => {
      ParserAssertions.expectRejected(JsonSamples.nestedUnknownValue(65));
    });

    it('rejects number with leading zero', 0, () => {
      ParserAssertions.expectRejected(JsonSamples.unknownValue('01'));
    });

    it('rejects number without fractional digits', 0, () => {
      ParserAssertions.expectRejected(JsonSamples.unknownValue('1.'));
    });

    it('rejects number without exponent digits', 0, () => {
      ParserAssertions.expectRejected(JsonSamples.unknownValue('1e'));
    });

    it('rejects incomplete literal', 0, () => {
      ParserAssertions.expectRejected(JsonSamples.unknownValue('tru'));
    });

    it('rejects invalid unicode hex digit', 0, () => {
      ParserAssertions.expectRejected(JsonSamples.unknownValue('"\\u12G4"'));
    });

    it('rejects incomplete unicode escape', 0, () => {
      ParserAssertions.expectRejected('{"bankName":"\\u12');
    });

    it('parses escaped and unicode strings', 0, () => {
      const text: string = '{"bankName":"Unicode \\u9898\\u5e93","subject":"语文","questions":[{"id":"1","type":"single_choice","question":"引号\\\" 反斜杠\\\\ 斜杠\\/ 退格\\b 换页\\f 换行\\n 回车\\r 制表\\t 中文\\u4e2d\\u6587","options":["A． 是","B. 否"],"answer":"a","analysis":"完整解析"}]}';
      const bank: QuestionBank = JsonParser.parse(text);
      expect(bank.bankName).assertEqual('Unicode 题库');
      expect(bank.questions[0].question).assertEqual('引号" 反斜杠\\ 斜杠/ 退格\b 换页\f 换行\n 回车\r 制表\t 中文中文');
      expect(bank.questions[0].answer).assertEqual('A');
    });

    it('rejects invalid string escape', 0, () => {
      const text: string = '{"bankName":"数学示例","subject":"数学","questions":[{"id":"1","type":"single_choice","question":"错误\\x转义","options":["A. 1","B. 2"],"answer":"A","analysis":"解析"}]}';
      ParserAssertions.expectRejected(text);
    });

    it('rejects raw string control character', 0, () => {
      const text: string = '{"bankName":"数学示例","subject":"数学","questions":[{"id":"1","type":"single_choice","question":"错误\n换行","options":["A. 1","B. 2"],"answer":"A","analysis":"解析"}]}';
      ParserAssertions.expectRejected(text);
    });

    it('rejects unclosed string', 0, () => {
      const text: string = '{"bankName":"未闭合';
      ParserAssertions.expectRejected(text);
    });

    it('rejects empty bank name', 0, () => {
      const text: string = '{"bankName":"   ","subject":"数学","questions":[{"id":"1","type":"single_choice","question":"题目","options":["A. 1","B. 2"],"answer":"A","analysis":"解析"}]}';
      ParserAssertions.expectRejected(text);
    });

    it('rejects empty questions', 0, () => {
      const text: string = '{"bankName":"数学示例","subject":"数学","questions":[]}';
      ParserAssertions.expectRejected(text);
    });

    it('rejects empty option', 0, () => {
      const text: string = '{"bankName":"数学示例","subject":"数学","questions":[{"id":"1","type":"single_choice","question":"题目","options":["A. 1","   "],"answer":"A","analysis":"解析"}]}';
      ParserAssertions.expectRejected(text);
    });

    it('rejects more than twenty options', 0, () => {
      ParserAssertions.expectRejected(JsonSamples.bankWithOptionCount(21));
    });

    it('rejects question text longer than twenty thousand characters', 0, () => {
      ParserAssertions.expectRejected(JsonSamples.bankWithQuestionTextLength(20001));
    });

    it('rejects more than five thousand questions', 0, () => {
      ParserAssertions.expectRejected(JsonSamples.bankWithQuestionCount(5001));
    });
  });

  describe('importResult', () => {
    it('creates successful result with bank id', 0, () => {
      const result: ImportResult = ImportResult.success('bank_1');
      expect(result.success).assertTrue();
      expect(result.cancelled).assertFalse();
      expect(result.errorCode.code).assertEqual(ImportErrorCode.SUCCESS);
      expect(result.bankId).assertEqual('bank_1');
    });

    it('creates cancelled result', 0, () => {
      const result: ImportResult = ImportResult.cancelled();
      expect(result.success).assertFalse();
      expect(result.cancelled).assertTrue();
      expect(result.errorCode.code).assertEqual(ImportErrorCode.CANCELLED);
    });

    it('creates stage specific error results', 0, () => {
      const format: ImportResult = ImportResult.formatError('format');
      const read: ImportResult = ImportResult.readError('read');
      const save: ImportResult = ImportResult.saveError('save');
      expect(format.errorCode.code).assertEqual(ImportErrorCode.FORMAT_ERROR);
      expect(read.errorCode.code).assertEqual(ImportErrorCode.READ_ERROR);
      expect(save.errorCode.code).assertEqual(ImportErrorCode.SAVE_ERROR);
      expect(format.message).assertEqual('format');
      expect(read.message).assertEqual('read');
      expect(save.message).assertEqual('save');
    });
  });

  describe('utf8Utils', () => {
    it('accepts valid Chinese UTF-8 bytes', 0, () => {
      const content: Uint8Array = new Uint8Array([0xE9, 0x94, 0x99, 0xE9, 0xA2, 0x98]);
      let accepted: boolean = true;
      try {
        Utf8Utils.validate(content);
      } catch (err) {
        accepted = false;
      }
      expect(accepted).assertTrue();
    });

    it('rejects malformed UTF-8 bytes', 0, () => {
      const content: Uint8Array = new Uint8Array([0xC3, 0x28]);
      let rejected: boolean = false;
      try {
        Utf8Utils.validate(content);
      } catch (err) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });
  });
}
