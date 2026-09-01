import { relationalStore } from '@kit.ArkData'
import { Question } from '../models/Question'
import { QuestionBank, QuestionBankSummary } from '../models/QuestionBank'
import { QuestionImage } from '../models/QuestionImage'
import { IdUtils } from '../utils/IdUtils'
import { DatabaseService } from './DatabaseService'

const BANK_COLUMNS: string = 'id, bank_name, subject, question_count, create_time, is_sample'
const QUESTION_COLUMNS: string = 'id, bank_id, type, content, options_json, answer, analysis, ' +
  'source_page_start, source_page_end, review_state'

class ImportedImageSnapshot {
  source: QuestionImage
  storedImageId: string
  storedQuestionId: string
  pageNumber: number
  imagePath: string
  sortOrder: number

  constructor(source: QuestionImage, storedImageId: string, storedQuestionId: string, pageNumber: number,
    imagePath: string, sortOrder: number) {
    this.source = source
    this.storedImageId = storedImageId
    this.storedQuestionId = storedQuestionId
    this.pageNumber = pageNumber
    this.imagePath = imagePath
    this.sortOrder = sortOrder
  }
}

class ImportedQuestionSnapshot {
  source: Question
  storedQuestionId: string
  type: string
  content: string
  optionsJson: string
  answer: string
  analysis: string
  sourcePageStart: number
  sourcePageEnd: number
  reviewState: string
  images: Array<ImportedImageSnapshot>

  constructor(source: Question, storedQuestionId: string, type: string, content: string,
    optionsJson: string, answer: string, analysis: string, sourcePageStart: number,
    sourcePageEnd: number, reviewState: string, images: Array<ImportedImageSnapshot>) {
    this.source = source
    this.storedQuestionId = storedQuestionId
    this.type = type
    this.content = content
    this.optionsJson = optionsJson
    this.answer = answer
    this.analysis = analysis
    this.sourcePageStart = sourcePageStart
    this.sourcePageEnd = sourcePageEnd
    this.reviewState = reviewState
    this.images = images
  }
}

class ImportedBankSnapshot {
  source: QuestionBank
  bankId: string
  bankName: string
  subject: string
  createTime: number
  isSample: boolean
  questions: Array<ImportedQuestionSnapshot>

  constructor(source: QuestionBank, bankId: string, bankName: string, subject: string,
    createTime: number, isSample: boolean, questions: Array<ImportedQuestionSnapshot>) {
    this.source = source
    this.bankId = bankId
    this.bankName = bankName
    this.subject = subject
    this.createTime = createTime
    this.isSample = isSample
    this.questions = questions
  }
}

export class PdfBankSaveUncertainError extends Error {
  readonly bankId: string
  readonly originalError: string
  readonly rollbackError: string

  constructor(bankId: string, originalError: string, rollbackError: string) {
    super('PDF 题库保存状态无法确认：' + originalError + '；事务回滚失败：' + rollbackError)
    this.bankId = bankId
    this.originalError = originalError
    this.rollbackError = rollbackError
  }
}

export class QuestionBankService {
  static async savePdfBank(bank: QuestionBank, bankId: string): Promise<string> {
    const createTime: number = bank.createTime > 0 ? bank.createTime : Date.now()
    const snapshot: ImportedBankSnapshot =
      QuestionBankService.createImportSnapshot(bank, false, bankId, createTime)
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const transaction: relationalStore.Transaction = await store.createTransaction()
    let committed: boolean = false
    try {
      const bankValues: relationalStore.ValuesBucket = {
        id: snapshot.bankId,
        bank_name: snapshot.bankName,
        subject: snapshot.subject,
        question_count: snapshot.questions.length,
        create_time: snapshot.createTime,
        is_sample: 0
      }
      const bankRowId: number = await transaction.insert('question_bank', bankValues)
      if (bankRowId < 0) {
        throw new Error('Failed to insert PDF question bank')
      }
      for (let index: number = 0; index < snapshot.questions.length; index++) {
        const questionSnapshot: ImportedQuestionSnapshot = snapshot.questions[index]
        const questionValues: relationalStore.ValuesBucket = {
          id: questionSnapshot.storedQuestionId,
          bank_id: snapshot.bankId,
          type: questionSnapshot.type,
          content: questionSnapshot.content,
          options_json: questionSnapshot.optionsJson,
          answer: questionSnapshot.answer,
          analysis: questionSnapshot.analysis,
          source_page_start: questionSnapshot.sourcePageStart,
          source_page_end: questionSnapshot.sourcePageEnd,
          review_state: questionSnapshot.reviewState
        }
        const questionRowId: number = await transaction.insert('question', questionValues)
        if (questionRowId < 0) {
          throw new Error('Failed to insert PDF question ' + questionSnapshot.storedQuestionId)
        }
        for (let imageIndex: number = 0; imageIndex < questionSnapshot.images.length; imageIndex++) {
          const imageSnapshot: ImportedImageSnapshot = questionSnapshot.images[imageIndex]
          const imageValues: relationalStore.ValuesBucket = {
            id: imageSnapshot.storedImageId,
            question_id: questionSnapshot.storedQuestionId,
            page_number: imageSnapshot.pageNumber,
            image_path: imageSnapshot.imagePath,
            sort_order: imageSnapshot.sortOrder
          }
          const imageRowId: number = await transaction.insert('question_image', imageValues)
          if (imageRowId < 0) {
            throw new Error('Failed to insert PDF question image ' + imageSnapshot.storedImageId)
          }
        }
      }
      await transaction.commit()
      committed = true
    } catch (err) {
      let rollbackError: string = ''
      try {
        await transaction.rollback()
      } catch (rollbackErr) {
        rollbackError = QuestionBankService.errorMessage(rollbackErr, '事务回滚失败')
      }
      if (rollbackError.length > 0) {
        throw new PdfBankSaveUncertainError(
          snapshot.bankId,
          QuestionBankService.errorMessage(err, 'PDF 题库保存失败'),
          rollbackError)
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to save PDF question bank')
    }
    if (!committed) {
      throw new Error('Failed to commit PDF question bank')
    }
    for (let index: number = 0; index < snapshot.questions.length; index++) {
      const questionSnapshot: ImportedQuestionSnapshot = snapshot.questions[index]
      questionSnapshot.source.id = questionSnapshot.storedQuestionId
      questionSnapshot.source.bankId = snapshot.bankId
      for (let imageIndex: number = 0; imageIndex < questionSnapshot.images.length; imageIndex++) {
        const imageSnapshot: ImportedImageSnapshot = questionSnapshot.images[imageIndex]
        imageSnapshot.source.id = imageSnapshot.storedImageId
        imageSnapshot.source.questionId = questionSnapshot.storedQuestionId
      }
    }
    snapshot.source.id = snapshot.bankId
    snapshot.source.questionCount = snapshot.questions.length
    snapshot.source.createTime = snapshot.createTime
    snapshot.source.isSample = false
    return snapshot.bankId
  }

  static async resolvePdfBankSave(bank: QuestionBank, bankId: string): Promise<string> {
    const snapshot: ImportedBankSnapshot =
      QuestionBankService.createImportSnapshot(bank, false, bankId, bank.createTime)
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const args: Array<relationalStore.ValueType> = [bankId]
    const bankResult: relationalStore.ResultSet = await store.querySql(
      'SELECT bank_name, subject, question_count, create_time, is_sample ' +
      'FROM question_bank WHERE id = ?', args)
    let bankRows: number = 0
    let bankMatches: boolean = true
    try {
      while (bankResult.goToNextRow()) {
        bankRows++
        if (bankRows > 1 || bankResult.getString(0) !== snapshot.bankName ||
          bankResult.getString(1) !== snapshot.subject ||
          bankResult.getLong(2) !== snapshot.questions.length ||
          bankResult.getLong(3) !== snapshot.createTime || bankResult.getLong(4) !== 0) {
          bankMatches = false
        }
      }
    } finally {
      bankResult.close()
    }

    const questionResult: relationalStore.ResultSet = await store.querySql(
      'SELECT id, type, content, options_json, answer, analysis, source_page_start, ' +
      'source_page_end, review_state FROM question WHERE bank_id = ? ORDER BY rowid ASC', args)
    let questionRows: number = 0
    let questionsMatch: boolean = true
    try {
      while (questionResult.goToNextRow()) {
        if (questionRows >= snapshot.questions.length) {
          questionsMatch = false
          questionRows++
          continue
        }
        const expected: ImportedQuestionSnapshot = snapshot.questions[questionRows]
        if (questionResult.getString(0) !== expected.storedQuestionId ||
          questionResult.getString(1) !== expected.type || questionResult.getString(2) !== expected.content ||
          questionResult.getString(3) !== expected.optionsJson || questionResult.getString(4) !== expected.answer ||
          questionResult.getString(5) !== expected.analysis ||
          questionResult.getLong(6) !== expected.sourcePageStart ||
          questionResult.getLong(7) !== expected.sourcePageEnd ||
          questionResult.getString(8) !== expected.reviewState) {
          questionsMatch = false
        }
        questionRows++
      }
    } finally {
      questionResult.close()
    }

    let imageRows: number = 0
    let imagesMatch: boolean = true
    let expectedImageCount: number = 0
    for (let questionIndex: number = 0; questionIndex < snapshot.questions.length; questionIndex++) {
      const expectedQuestion: ImportedQuestionSnapshot = snapshot.questions[questionIndex]
      expectedImageCount += expectedQuestion.images.length
      const imageArgs: Array<relationalStore.ValueType> = [expectedQuestion.storedQuestionId]
      const imageResult: relationalStore.ResultSet = await store.querySql(
        'SELECT id, question_id, page_number, image_path, sort_order FROM question_image ' +
        'WHERE question_id = ? ORDER BY sort_order ASC, rowid ASC', imageArgs)
      let questionImageRows: number = 0
      try {
        while (imageResult.goToNextRow()) {
          if (questionImageRows >= expectedQuestion.images.length) {
            imagesMatch = false
            questionImageRows++
            imageRows++
            continue
          }
          const expected: ImportedImageSnapshot = expectedQuestion.images[questionImageRows]
          if (imageResult.getString(0) !== expected.storedImageId ||
            imageResult.getString(1) !== expected.storedQuestionId ||
            imageResult.getLong(2) !== expected.pageNumber ||
            imageResult.getString(3) !== expected.imagePath ||
            imageResult.getLong(4) !== expected.sortOrder) {
            imagesMatch = false
          }
          questionImageRows++
          imageRows++
        }
      } finally {
        imageResult.close()
      }
      if (questionImageRows !== expectedQuestion.images.length) {
        imagesMatch = false
      }
    }

    if (bankRows === 0 && questionRows === 0 && imageRows === 0) {
      return 'absent'
    }
    if (bankRows === 1 && bankMatches && questionsMatch && imagesMatch &&
      questionRows === snapshot.questions.length && imageRows === expectedImageCount) {
      return 'committed'
    }
    return 'inconsistent'
  }

  static async saveImportedBank(bank: QuestionBank, isSample: boolean): Promise<string> {
    const bankId: string = IdUtils.create('bank_')
    const createTime: number = Date.now()
    const snapshot: ImportedBankSnapshot =
      QuestionBankService.createImportSnapshot(bank, isSample, bankId, createTime)
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const transaction: relationalStore.Transaction = await store.createTransaction()
    let committed: boolean = false
    try {
      const bankValues: relationalStore.ValuesBucket = {
        id: snapshot.bankId,
        bank_name: snapshot.bankName,
        subject: snapshot.subject,
        question_count: snapshot.questions.length,
        create_time: snapshot.createTime,
        is_sample: snapshot.isSample ? 1 : 0
      }
      const bankRowId: number = await transaction.insert('question_bank', bankValues)
      if (bankRowId < 0) {
        throw new Error('Failed to insert question bank')
      }
      for (let index: number = 0; index < snapshot.questions.length; index++) {
        const questionSnapshot: ImportedQuestionSnapshot = snapshot.questions[index]
        const questionValues: relationalStore.ValuesBucket = {
          id: questionSnapshot.storedQuestionId,
          bank_id: snapshot.bankId,
          type: questionSnapshot.type,
          content: questionSnapshot.content,
          options_json: questionSnapshot.optionsJson,
          answer: questionSnapshot.answer,
          analysis: questionSnapshot.analysis,
          source_page_start: questionSnapshot.sourcePageStart,
          source_page_end: questionSnapshot.sourcePageEnd,
          review_state: questionSnapshot.reviewState
        }
        const questionRowId: number = await transaction.insert('question', questionValues)
        if (questionRowId < 0) {
          throw new Error('Failed to insert question ' + questionSnapshot.storedQuestionId)
        }
        for (let imageIndex: number = 0; imageIndex < questionSnapshot.images.length; imageIndex++) {
          const imageSnapshot: ImportedImageSnapshot = questionSnapshot.images[imageIndex]
          const imageValues: relationalStore.ValuesBucket = {
            id: imageSnapshot.storedImageId,
            question_id: questionSnapshot.storedQuestionId,
            page_number: imageSnapshot.pageNumber,
            image_path: imageSnapshot.imagePath,
            sort_order: imageSnapshot.sortOrder
          }
          const imageRowId: number = await transaction.insert('question_image', imageValues)
          if (imageRowId < 0) {
            throw new Error('Failed to insert question image ' + imageSnapshot.storedImageId)
          }
        }
      }
      await transaction.commit()
      committed = true
    } catch (err) {
      // 任一写入失败时撤销整批题库。
      try {
        await transaction.rollback()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to save question bank')
    }
    if (!committed) {
      throw new Error('Failed to commit question bank')
    }
    for (let index: number = 0; index < snapshot.questions.length; index++) {
      const questionSnapshot: ImportedQuestionSnapshot = snapshot.questions[index]
      questionSnapshot.source.id = questionSnapshot.storedQuestionId
      questionSnapshot.source.bankId = snapshot.bankId
      for (let imageIndex: number = 0; imageIndex < questionSnapshot.images.length; imageIndex++) {
        const imageSnapshot: ImportedImageSnapshot = questionSnapshot.images[imageIndex]
        imageSnapshot.source.id = imageSnapshot.storedImageId
        imageSnapshot.source.questionId = questionSnapshot.storedQuestionId
      }
    }
    snapshot.source.id = snapshot.bankId
    snapshot.source.questionCount = snapshot.questions.length
    snapshot.source.createTime = snapshot.createTime
    snapshot.source.isSample = snapshot.isSample
    return snapshot.bankId
  }

  private static createImportSnapshot(bank: QuestionBank, isSample: boolean,
    bankId: string, createTime: number): ImportedBankSnapshot {
    const sourceQuestions: Array<Question> = bank.questions.slice()
    const questionSnapshots: Array<ImportedQuestionSnapshot> = new Array<ImportedQuestionSnapshot>()
    for (let index: number = 0; index < sourceQuestions.length; index++) {
      const sourceQuestion: Question = sourceQuestions[index]
      const storedQuestionId: string = bankId + '_' + sourceQuestion.id
      const optionValues: Array<string> = sourceQuestion.options.slice()
      const sourceImages: Array<QuestionImage> = sourceQuestion.images.slice()
      const imageSnapshots: Array<ImportedImageSnapshot> = new Array<ImportedImageSnapshot>()
      for (let imageIndex: number = 0; imageIndex < sourceImages.length; imageIndex++) {
        const sourceImage: QuestionImage = sourceImages[imageIndex]
        const storedImageId: string = storedQuestionId + '_image_' + imageIndex.toString()
        imageSnapshots.push(new ImportedImageSnapshot(
          sourceImage,
          storedImageId,
          storedQuestionId,
          sourceImage.pageNumber,
          sourceImage.imagePath,
          sourceImage.sortOrder))
      }
      questionSnapshots.push(new ImportedQuestionSnapshot(
        sourceQuestion,
        storedQuestionId,
        sourceQuestion.type,
        sourceQuestion.question,
        JSON.stringify(optionValues),
        sourceQuestion.answer,
        sourceQuestion.analysis,
        sourceQuestion.sourcePageStart,
        sourceQuestion.sourcePageEnd,
        sourceQuestion.reviewState,
        imageSnapshots))
    }
    return new ImportedBankSnapshot(
      bank,
      bankId,
      bank.bankName,
      bank.subject,
      createTime,
      isSample,
      questionSnapshots)
  }

  static async listBanks(): Promise<Array<QuestionBankSummary>> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT ' + BANK_COLUMNS + ' FROM question_bank ORDER BY create_time DESC')
    const banks: Array<QuestionBankSummary> = new Array<QuestionBankSummary>()
    try {
      while (resultSet.goToNextRow()) {
        banks.push(QuestionBankService.mapBankSummary(resultSet))
      }
      return banks
    } finally {
      resultSet.close()
    }
  }

  static async getBank(id: string): Promise<QuestionBank | null> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const args: Array<relationalStore.ValueType> = [id]
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT ' + BANK_COLUMNS + ' FROM question_bank WHERE id = ?', args)
    let summary: QuestionBankSummary | null = null
    try {
      if (resultSet.goToFirstRow()) {
        summary = QuestionBankService.mapBankSummary(resultSet)
      }
    } finally {
      resultSet.close()
    }
    if (summary === null) {
      return null
    }
    const questions: Array<Question> = await QuestionBankService.listQuestions(id)
    return new QuestionBank(summary.id, summary.bankName, summary.subject, summary.questionCount,
      summary.createTime, summary.isSample, questions)
  }

  static async listQuestions(bankId: string): Promise<Array<Question>> {
    const args: Array<relationalStore.ValueType> = [bankId]
    return QuestionBankService.queryQuestions(
      'SELECT ' + QUESTION_COLUMNS + ' FROM question WHERE bank_id = ? ORDER BY rowid ASC', args)
  }

  static async getQuestion(id: string): Promise<Question | null> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const args: Array<relationalStore.ValueType> = [id]
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT ' + QUESTION_COLUMNS + ' FROM question WHERE id = ?', args)
    let question: Question | null = null
    try {
      if (!resultSet.goToFirstRow()) {
        return null
      }
      question = QuestionBankService.mapQuestion(resultSet)
    } finally {
      resultSet.close()
    }
    if (question === null) {
      return null
    }
    question.images = await QuestionBankService.listQuestionImages(question.id)
    return question
  }

  static async searchQuestions(bankId: string, query: string): Promise<Array<Question>> {
    if (query.trim().length === 0) {
      return QuestionBankService.listQuestions(bankId)
    }
    const args: Array<relationalStore.ValueType> = [bankId, query]
    return QuestionBankService.queryQuestions(
      'SELECT ' + QUESTION_COLUMNS +
      ' FROM question WHERE bank_id = ? AND instr(content, ?) > 0 ORDER BY rowid ASC', args)
  }

  static async updateQuestion(question: Question): Promise<void> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const transaction: relationalStore.Transaction = await store.createTransaction()
    const storedReviewState: string = question.question.trim().length > 0 ? 'confirmed' : question.reviewState
    try {
      const values: relationalStore.ValuesBucket = {
        type: question.type,
        content: question.question,
        options_json: JSON.stringify(question.options),
        answer: question.answer,
        analysis: question.analysis,
        review_state: storedReviewState
      }
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('question')
      predicates.equalTo('id', question.id)
      const changedRows: number = await transaction.update(values, predicates)
      if (changedRows !== 1) {
        throw new Error('Failed to update question ' + question.id)
      }
      await transaction.commit()
      question.reviewState = storedReviewState
    } catch (err) {
      try {
        await transaction.rollback()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to update question')
    }
  }

  static async deleteBank(id: string): Promise<Array<string>> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const args: Array<relationalStore.ValueType> = [id]
    const transaction: relationalStore.Transaction = await store.createTransaction()
    const imagePaths: Array<string> = new Array<string>()
    try {
      const imageResultSet: relationalStore.ResultSet = await transaction.querySql(
        'SELECT qi.image_path FROM question_image qi INNER JOIN question q ON q.id = qi.question_id ' +
        'WHERE q.bank_id = ? ORDER BY qi.rowid ASC', args)
      try {
        while (imageResultSet.goToNextRow()) {
          const imagePath: string = imageResultSet.getString(0)
          if (imagePaths.indexOf(imagePath) < 0) {
            imagePaths.push(imagePath)
          }
        }
      } finally {
        imageResultSet.close()
      }
      const createTime: number = Date.now()
      for (let index: number = 0; index < imagePaths.length; index++) {
        const debtArgs: Array<relationalStore.ValueType> = [imagePaths[index], createTime]
        await transaction.execute(
          'INSERT OR IGNORE INTO question_image_cleanup_debt(path, create_time) VALUES (?, ?)', debtArgs)
      }
      await transaction.execute(
        'DELETE FROM question_image WHERE question_id IN (SELECT id FROM question WHERE bank_id = ?)', args)
      await transaction.execute('DELETE FROM wrong_question WHERE bank_id = ?', args)
      await transaction.execute('DELETE FROM question WHERE bank_id = ?', args)
      await transaction.execute('DELETE FROM question_bank WHERE id = ?', args)
      await transaction.commit()
      return imagePaths
    } catch (err) {
      // 任一删除失败时恢复题库关联数据。
      try {
        await transaction.rollback()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to delete question bank')
    }
  }

  private static async queryQuestions(sql: string,
    args: Array<relationalStore.ValueType>): Promise<Array<Question>> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const resultSet: relationalStore.ResultSet = await store.querySql(sql, args)
    const questions: Array<Question> = new Array<Question>()
    try {
      while (resultSet.goToNextRow()) {
        questions.push(QuestionBankService.mapQuestion(resultSet))
      }
    } finally {
      resultSet.close()
    }
    return questions
  }

  private static async listQuestionImages(questionId: string): Promise<Array<QuestionImage>> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const args: Array<relationalStore.ValueType> = [questionId]
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT id, question_id, page_number, image_path, sort_order FROM question_image ' +
      'WHERE question_id = ? ORDER BY sort_order ASC, rowid ASC', args)
    const images: Array<QuestionImage> = new Array<QuestionImage>()
    try {
      while (resultSet.goToNextRow()) {
        images.push(new QuestionImage(
          resultSet.getString(0),
          resultSet.getString(1),
          resultSet.getLong(2),
          resultSet.getString(3),
          resultSet.getLong(4)))
      }
      return images
    } finally {
      resultSet.close()
    }
  }

  private static mapBankSummary(resultSet: relationalStore.ResultSet): QuestionBankSummary {
    return new QuestionBankSummary(
      resultSet.getString(0),
      resultSet.getString(1),
      resultSet.getString(2),
      resultSet.getLong(3),
      resultSet.getLong(4),
      resultSet.getLong(5) === 1)
  }

  private static mapQuestion(resultSet: relationalStore.ResultSet): Question {
    const options: Array<string> = JSON.parse(resultSet.getString(4))
    return new Question(
      resultSet.getString(0),
      resultSet.getString(1),
      resultSet.getString(2),
      resultSet.getString(3),
      options,
      resultSet.getString(5),
      resultSet.getString(6),
      resultSet.getLong(7),
      resultSet.getLong(8),
      resultSet.getString(9))
  }

  private static errorMessage(err: Error, fallback: string): string {
    return err instanceof Error && err.message.length > 0 ? err.message : fallback
  }
}
