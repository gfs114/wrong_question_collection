import { Question } from '../models/Question'

export class SyncPayloadFactory {
  static bankPayload(name: string, subject: string): string {
    return '{"name":' + JSON.stringify(name) + ',"subject":' + JSON.stringify(subject) + '}'
  }

  static questionPayload(question: Question, bankClientId: string): string {
    return SyncPayloadFactory.questionFieldsPayload(
      question.type, question.question, question.options, question.answer, question.analysis, bankClientId)
  }

  static questionFieldsPayload(type: string, question: string, options: Array<string>,
    answer: string, analysis: string, bankClientId: string): string {
    const optionEntries: Array<string> = new Array<string>()
    for (let index: number = 0; index < options.length; index++) {
      optionEntries.push(JSON.stringify(index.toString()) + ':' + JSON.stringify(options[index]))
    }
    return '{"bankClientId":' + JSON.stringify(bankClientId) +
      ',"type":' + JSON.stringify(type) +
      ',"question":' + JSON.stringify(question) +
      ',"options":{' + optionEntries.join(',') + '}' +
      ',"answer":' + JSON.stringify(answer) +
      ',"analysis":' + JSON.stringify(analysis) + '}'
  }

  static wrongQuestionPayload(mastered: boolean): string {
    return '{"status":' + JSON.stringify(mastered ? 'mastered' : 'pending') + '}'
  }
}
