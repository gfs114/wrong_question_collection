export class QuestionImage {
  id: string
  questionId: string
  pageNumber: number
  imagePath: string
  sortOrder: number

  constructor(id: string, questionId: string, pageNumber: number, imagePath: string, sortOrder: number) {
    this.id = id
    this.questionId = questionId
    this.pageNumber = pageNumber
    this.imagePath = imagePath
    this.sortOrder = sortOrder
  }
}
