import { Context } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'
import { BusinessError } from '@kit.BasicServicesKit'
import { connection } from '@kit.NetworkKit'
import fs from '@ohos.file.fs'
import { AppHeader } from '../components/AppHeader'
import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  CONTENT_MAX_WIDTH,
  PAGE_PADDING,
  SUBTITLE_FONT_SIZE,
  themePalette
} from '../constants/AppTheme'
import { AccountSessionState } from '../models/AccountSession'
import { ApiHttpError } from '../models/ApiModels'
import { CloudImportJob, CloudImportUploadRequest } from '../models/CloudImportModels'
import { PdfPageRangeValidation } from '../models/PdfImportModels'
import { AccountSessionService } from '../services/AccountSessionService'
import { ApiHttpClient } from '../services/ApiHttpClient'
import { CloudImportService } from '../services/CloudImportService'
import { AppColors } from '../theme/AppColors'
import { CloudPdfSelection, PdfImportState } from '../utils/PdfImportState'
import { PdfImportValidator } from '../utils/PdfImportValidator'
import { SafeAreaInsets, SafeAreaUtils } from '../utils/SafeAreaUtils'

@Entry
@Component
struct PdfImportSetupPage {
  @State bankName: string = ''
  @State subject: string = ''
  @State startPageText: string = '1'
  @State endPageText: string = '1'
  @State errorMessage: string = ''
  @State fileName: string = ''
  @State fileSize: number = 0
  @State customSubject: boolean = false
  @State selectionReady: boolean = false
  @State creating: boolean = false
  @State leaving: boolean = false
  @StorageProp('safeAreaInsets') safeAreaInsets: SafeAreaInsets = {
    top: 0, left: 0, right: 0, bottom: 0
  }
  @StorageProp('darkMode') darkMode: boolean = false
  private subjects: Array<string> = ['数学', '语文', '英语', '物理', '化学', '其他']

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  aboutToAppear(): void {
    const state: PdfImportState = PdfImportState.shared()
    const selection: CloudPdfSelection | null = state.getCloudSelection()
    if (selection === null) {
      this.selectionReady = false
      this.errorMessage = '未找到已选择的 PDF，请返回重新选择'
      return
    }
    this.fileName = selection.fileName
    this.fileSize = selection.sourceSize
    const job: CloudImportJob | null = state.getCloudJob()
    if (job === null) {
      this.bankName = PdfImportValidator.bankNameFromFileName(selection.fileName)
    } else {
      this.bankName = job.bankName
      this.subject = job.subject
      this.startPageText = job.pageStart.toString()
      this.endPageText = job.pageEnd.toString()
      this.customSubject = this.subjects.indexOf(job.subject) < 0
    }
    this.selectionReady = true
    this.errorMessage = ''
  }

  onBackPress(): boolean {
    this.leaveImport()
    return true
  }

  private selectSubject(value: string): void {
    if (this.creating || this.leaving) {
      return
    }
    this.customSubject = value === '其他'
    this.subject = this.customSubject ? '' : value
    this.errorMessage = ''
  }

  private isSubjectSelected(value: string): boolean {
    if (value === '其他') {
      return this.customSubject
    }
    return !this.customSubject && this.subject === value
  }

  private isPositiveIntegerText(value: string): boolean {
    if (value.length === 0) {
      return false
    }
    for (let index: number = 0; index < value.length; index++) {
      const code: number = value.charCodeAt(index)
      if (code < 48 || code > 57) {
        return false
      }
    }
    return true
  }

  private startCloudImport(): void {
    if (this.creating || this.leaving) {
      return
    }
    this.creating = true
    this.errorMessage = ''
    this.prepareCloudImport().catch((err: Error) => {
      this.errorMessage = this.messageForError(err)
    }).finally(() => {
      this.creating = false
    })
  }

  private async prepareCloudImport(): Promise<void> {
    const context: Context = getContext(this)
    const state: PdfImportState = PdfImportState.shared()
    const selection: CloudPdfSelection | null = state.getCloudSelection()
    if (selection === null) {
      throw new Error('未找到已选择的 PDF，请返回重新选择')
    }
    const session: AccountSessionState = await AccountSessionService.state(context)
    if (!session.signedIn || session.userId.trim().length === 0) {
      throw new Error('请先登录华为账号')
    }
    if (!(await this.hasUsableNetwork())) {
      throw new Error('当前网络不可用，请连接网络后重试')
    }
    const trimmedBankName: string = this.bankName.trim()
    const trimmedSubject: string = this.subject.trim()
    if (trimmedBankName.length === 0 || trimmedBankName.length > 255) {
      throw new Error('题库名称无效，请输入 1 至 255 个字符')
    }
    if (trimmedSubject.length === 0 || trimmedSubject.length > 64) {
      throw new Error('学科无效，请输入 1 至 64 个字符')
    }
    if (!this.isPositiveIntegerText(this.startPageText) ||
      !this.isPositiveIntegerText(this.endPageText)) {
      throw new Error('页码必须是从 1 开始的正整数')
    }
    const pageStart: number = Number.parseInt(this.startPageText, 10)
    const pageEnd: number = Number.parseInt(this.endPageText, 10)
    const validation: PdfPageRangeValidation = PdfImportValidator.validatePageRange(
      pageStart, pageEnd, 20)
    if (!validation.valid) {
      throw new Error(validation.message)
    }
    await this.validatePdfFile(selection)
    let job: CloudImportJob | null = state.getCloudJob()
    if (job !== null && state.getCloudAccountId() !== session.userId) {
      throw new Error('当前账号与云端导入任务不一致，请返回重新选择')
    }
    if (job === null) {
      const request: CloudImportUploadRequest = new CloudImportUploadRequest(selection.pdfPath,
        trimmedBankName, trimmedSubject, pageStart, pageEnd)
      job = await CloudImportService.createJob(context, request)
      state.setCloudAccountId(session.userId)
      state.setCloudJob(job)
      state.setFirstMissingPart(0)
      state.setCloudReviewDraft(null)
      state.setConfirmResult(null)
    }
    const options: router.RouterOptions = {
      url: 'pages/PdfImportProgressPage'
    }
    await this.getUIContext().getRouter().pushUrl(options)
  }

  private async hasUsableNetwork(): Promise<boolean> {
    try {
      if (connection.hasDefaultNetSync()) {
        return true
      }
    } catch {
    }
    try {
      await ApiHttpClient.get<void>('/v1/imports/pdf')
      return true
    } catch (err) {
      if (err instanceof ApiHttpError && err.statusCode > 0) {
        return true
      }
      return false
    }
  }

  private async validatePdfFile(selection: CloudPdfSelection): Promise<void> {
    const info: fs.Stat = await fs.lstat(selection.pdfPath)
    if (info.isSymbolicLink() || !info.isFile() || !Number.isSafeInteger(info.size) ||
      info.size <= 0 || info.size !== selection.sourceSize) {
      throw new Error('PDF 文件不存在或已发生变化，请返回重新选择')
    }
  }

  private leaveImport(): void {
    if (this.creating || this.leaving) {
      return
    }
    this.leaving = true
    this.finishLeaving().catch(() => {
      this.errorMessage = 'PDF 临时文件清理失败，请稍后重试'
    }).finally(() => {
      this.leaving = false
    })
  }

  private async finishLeaving(): Promise<void> {
    const state: PdfImportState = PdfImportState.shared()
    if (state.getCloudJob() === null) {
      const selection: CloudPdfSelection | null = state.getCloudSelection()
      if (selection !== null) {
        const info: fs.Stat | null = await this.lstatIfPresent(selection.pdfPath)
        if (info !== null && !info.isSymbolicLink() && info.isFile()) {
          await fs.unlink(selection.pdfPath)
        }
      }
      state.reset()
    }
    this.getUIContext().getRouter().back()
  }

  private async lstatIfPresent(path: string): Promise<fs.Stat | null> {
    return new Promise<fs.Stat | null>((resolve, reject): void => {
      fs.lstat(path, (err: BusinessError, info: fs.Stat): void => {
        if (err) {
          if (err.code === 13900002) {
            resolve(null)
            return
          }
          reject(new Error(err.message.length > 0 ? err.message : '文件状态读取失败'))
          return
        }
        resolve(info)
      })
    })
  }

  private messageForError(err: Error): string {
    if (err instanceof Error && err.message.length > 0) {
      return err.message
    }
    return '云端导入任务创建失败，请稍后重试'
  }

  build() {
    Column() {
      AppHeader({
        title: 'PDF 导入设置',
        showBack: true,
        onBack: () => {
          this.leaveImport()
        }
      })

      if (!this.selectionReady) {
        Column({ space: 18 }) {
          Text(this.errorMessage)
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().error)
            .textAlign(TextAlign.Center)

          Button('返回导入')
            .type(ButtonType.Normal)
            .height(48)
            .backgroundColor(this.colors().brand)
            .fontColor(this.colors().onBrand)
            .borderRadius(14)
            .onClick(() => {
              this.leaveImport()
            })
        }
        .layoutWeight(1)
        .width('100%')
        .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
        .padding(PAGE_PADDING)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 16 }) {
            Column({ space: 8 }) {
              Text(this.fileName)
                .width('100%')
                .fontSize(SUBTITLE_FONT_SIZE)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.colors().textPrimary)
                .maxLines(2)

              Text('文件大小 ' + Math.ceil(this.fileSize / 1024).toString() + ' KB')
                .fontSize(BODY_FONT_SIZE)
                .fontColor(this.colors().textCaption)

              Text('PDF 将上传到服务器识别，单次最多识别 20 页')
                .fontSize(BODY_FONT_SIZE)
                .fontColor(this.colors().textCaption)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(18)
            .backgroundColor(this.colors().cardBackground)
            .borderRadius(CARD_RADIUS)

            Column({ space: 10 }) {
              Text('题库名')
                .fontSize(SUBTITLE_FONT_SIZE)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.colors().textPrimary)

              TextInput({ placeholder: '请输入题库名', text: this.bankName })
                .width('100%')
                .height(50)
                .fontSize(BODY_FONT_SIZE)
                .fontColor(this.colors().textPrimary)
                .backgroundColor(this.colors().pageBackground)
                .borderRadius(14)
                .onChange((value: string) => {
                  this.bankName = value
                  this.errorMessage = ''
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(18)
            .backgroundColor(this.colors().cardBackground)
            .borderRadius(CARD_RADIUS)

            Column({ space: 12 }) {
              Text('选择科目')
                .fontSize(SUBTITLE_FONT_SIZE)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.colors().textPrimary)

              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.subjects, (item: string) => {
                  Button(item)
                    .type(ButtonType.Normal)
                    .height(42)
                    .margin({ right: 8, bottom: 8 })
                    .padding({ left: 18, right: 18 })
                    .fontSize(BODY_FONT_SIZE)
                    .fontColor(this.isSubjectSelected(item) ?
                      this.colors().onBrand : this.colors().textPrimary)
                    .backgroundColor(this.isSubjectSelected(item) ?
                      this.colors().brand : this.colors().pageBackground)
                    .borderRadius(21)
                    .onClick(() => {
                      this.selectSubject(item)
                    })
                }, (item: string): string => item)
              }
              .width('100%')

              if (this.customSubject) {
                TextInput({ placeholder: '请输入科目', text: this.subject })
                  .width('100%')
                  .height(50)
                  .fontSize(BODY_FONT_SIZE)
                  .fontColor(this.colors().textPrimary)
                  .backgroundColor(this.colors().pageBackground)
                  .borderRadius(14)
                  .onChange((value: string) => {
                    this.subject = value
                    this.errorMessage = ''
                  })
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(18)
            .backgroundColor(this.colors().cardBackground)
            .borderRadius(CARD_RADIUS)

            Row({ space: 12 }) {
              Column({ space: 8 }) {
                Text('起始页')
                  .fontSize(BODY_FONT_SIZE)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.colors().textPrimary)
                TextInput({ placeholder: '1', text: this.startPageText })
                  .type(InputType.Number)
                  .height(48)
                  .backgroundColor(this.colors().pageBackground)
                  .borderRadius(14)
                  .onChange((value: string) => {
                    this.startPageText = value
                    this.errorMessage = ''
                  })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Column({ space: 8 }) {
                Text('结束页')
                  .fontSize(BODY_FONT_SIZE)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.colors().textPrimary)
                TextInput({ placeholder: '1', text: this.endPageText })
                  .type(InputType.Number)
                  .height(48)
                  .backgroundColor(this.colors().pageBackground)
                  .borderRadius(14)
                  .onChange((value: string) => {
                    this.endPageText = value
                    this.errorMessage = ''
                  })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding(18)
            .backgroundColor(this.colors().cardBackground)
            .borderRadius(CARD_RADIUS)

            if (this.errorMessage.length > 0) {
              Text(this.errorMessage)
                .width('100%')
                .padding(16)
                .fontSize(BODY_FONT_SIZE)
                .fontColor(this.colors().error)
                .backgroundColor(this.colors().errorSoft)
                .borderRadius(14)
            }

            Button(this.creating ? '正在创建云端任务…' : '开始云端识别')
              .type(ButtonType.Normal)
              .width('100%')
              .height(52)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.colors().onBrand)
              .backgroundColor(this.colors().brand)
              .borderRadius(16)
              .enabled(!this.creating && !this.leaving)
              .onClick(() => {
                this.startCloudImport()
              })
          }
          .width('100%')
          .padding({
            left: PAGE_PADDING,
            right: PAGE_PADDING,
            bottom: PAGE_PADDING + SafeAreaUtils.bottom(this.safeAreaInsets)
          })
        }
        .layoutWeight(1)
        .width('100%')
        .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
