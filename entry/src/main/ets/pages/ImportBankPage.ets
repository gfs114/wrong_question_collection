import { Context } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'
import { BusinessError } from '@kit.BasicServicesKit'
import fs from '@ohos.file.fs'
import picker from '@ohos.file.picker'
import { AppHeader } from '../components/AppHeader'
import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  COLOR_CARD_BG,
  COLOR_DANGER,
  COLOR_PAGE_BG,
  COLOR_PRIMARY,
  COLOR_TEXT_CAPTION,
  COLOR_TEXT_PRIMARY,
  PAGE_PADDING,
  SUBTITLE_FONT_SIZE
} from '../constants/AppTheme'
import { PdfImportLimits } from '../constants/PdfImportLimits'
import { ImportErrorCode, ImportResult } from '../models/ImportResult'
import { AccountSessionState } from '../models/AccountSession'
import { AccountSessionService } from '../services/AccountSessionService'
import { ImportService } from '../services/ImportService'
import { CloudPdfSelection, PdfImportState } from '../utils/PdfImportState'

@Entry
@Component
struct ImportBankPage {
  @State importing: boolean = false
  @State pdfSelecting: boolean = false
  @State errorMessage: string = ''

  private goBack(): void {
    if (this.importing || this.pdfSelecting) {
      return
    }
    try {
      this.getUIContext().getRouter().back()
    } catch {
    }
  }

  onBackPress(): boolean {
    this.goBack()
    return true
  }

  private startImport(): void {
    if (this.importing || this.pdfSelecting) {
      return
    }
    const hostContext: Context | undefined = this.getUIContext().getHostContext()
    if (hostContext === undefined) {
      this.showToast('暂时无法获取应用上下文')
      return
    }
    AccountSessionService.state(hostContext)
      .then((session: AccountSessionState) => {
        if (!session.signedIn) {
          this.showToast('请先登录华为账号')
          return
        }
        this.importing = true
        this.errorMessage = ''
        this.importBank()
      })
      .catch(() => {
        this.showToast('导入失败，请稍后重试')
      })
  }

  private async importBank(): Promise<void> {
    let result: ImportResult
    try {
      result = await ImportService.selectAndImport(getContext(this))
    } catch {
      this.errorMessage = '导入失败，请稍后重试'
      this.importing = false
      return
    }
    this.importing = false
    if (result.cancelled) {
      return
    }
    if (result.success) {
      this.showToast('题库导入成功')
      this.goBack()
      return
    }
    this.errorMessage = this.messageFor(result.errorCode.code)
  }

  private messageFor(errorCode: string): string {
    if (errorCode === ImportErrorCode.FORMAT_ERROR) {
      return '题库格式错误，请检查 JSON 文件'
    }
    if (errorCode === ImportErrorCode.READ_ERROR) {
      return '文件读取失败，请重新选择'
    }
    if (errorCode === ImportErrorCode.SAVE_ERROR) {
      return '题库保存失败，请稍后重试'
    }
    return '导入失败，请稍后重试'
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message })
    } catch {
    }
  }

  private async selectPdf(): Promise<void> {
    if (this.importing || this.pdfSelecting) {
      return
    }
    this.pdfSelecting = true
    this.errorMessage = ''
    let stagedPath: string = ''
    let selectionStored: boolean = false
    try {
      const context: Context = getContext(this)
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context)
      const pickerOptions: picker.DocumentSelectOptions = new picker.DocumentSelectOptions()
      pickerOptions.fileSuffixFilters = ['PDF文件|.pdf']
      pickerOptions.maxSelectNumber = 1
      const selectedUris: Array<string> = await documentPicker.select(pickerOptions)
      if (selectedUris.length === 0) {
        return
      }
      const sourceUri: string = selectedUris[0]
      const sourceFile: fs.File = await fs.open(sourceUri, fs.OpenMode.READ_ONLY)
      let sourceSize: number = 0
      let fileName: string = 'selected.pdf'
      try {
        const sourceInfo: fs.Stat = await fs.stat(sourceFile.fd)
        sourceSize = sourceInfo.size
        if (!Number.isSafeInteger(sourceSize) || sourceSize <= 0 ||
          sourceSize > PdfImportLimits.MAX_FILE_BYTES) {
          throw new Error('PDF 文件大小无效或超过限制')
        }
        fileName = this.resolveFileName(sourceUri, sourceFile.name)
        stagedPath = context.cacheDir + '/cloud_import_pdf_' + Date.now().toString() + '.pdf'
        await this.copyPdf(sourceFile.fd, stagedPath, sourceSize)
      } finally {
        await fs.close(sourceFile)
      }
      const stagedInfo: fs.Stat = await fs.lstat(stagedPath)
      if (stagedInfo.isSymbolicLink() || !stagedInfo.isFile() ||
        stagedInfo.size !== sourceSize) {
        throw new Error('PDF 暂存文件校验失败')
      }
      const state: PdfImportState = PdfImportState.shared()
      const previousSelection: CloudPdfSelection | null = state.getCloudSelection()
      if (previousSelection !== null && previousSelection.pdfPath !== stagedPath) {
        await this.removeStagedPdf(context.cacheDir, previousSelection.pdfPath)
      }
      state.reset()
      state.setCloudSelection(new CloudPdfSelection(stagedPath, fileName, sourceSize))
      selectionStored = true
      const options: router.RouterOptions = {
        url: 'pages/PdfImportSetupPage'
      }
      await this.getUIContext().getRouter().pushUrl(options)
    } catch (err) {
      this.errorMessage = this.messageForPdfError(err)
      if (stagedPath.length > 0) {
        try {
          await this.removeStagedPdf(getContext(this).cacheDir, stagedPath)
        } catch {
          this.errorMessage = this.errorMessage + '；PDF 临时文件清理失败，请重试'
        }
      }
      if (selectionStored) {
        PdfImportState.shared().reset()
      }
    } finally {
      this.pdfSelecting = false
    }
  }

  private async copyPdf(sourceFd: number, stagedPath: string, expectedSize: number): Promise<void> {
    const targetFile: fs.File = await fs.open(stagedPath,
      fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.NOFOLLOW)
    let totalCopied: number = 0
    try {
      const buffer: ArrayBuffer = new ArrayBuffer(64 * 1024)
      while (totalCopied < expectedSize) {
        const bytesRead: number = await fs.read(sourceFd, buffer)
        if (!Number.isInteger(bytesRead) || bytesRead <= 0 || bytesRead > buffer.byteLength) {
          throw new Error('PDF 文件在读取期间发生变化')
        }
        const nextTotal: number = totalCopied + bytesRead
        if (!Number.isSafeInteger(nextTotal) || nextTotal > expectedSize ||
          nextTotal > PdfImportLimits.MAX_FILE_BYTES) {
          throw new Error('PDF 文件在读取期间超过大小限制')
        }
        let written: number = 0
        while (written < bytesRead) {
          const writeBuffer: ArrayBuffer = buffer.slice(written, bytesRead)
          const currentWrite: number = await fs.write(targetFile.fd, writeBuffer)
          if (!Number.isInteger(currentWrite) || currentWrite <= 0 ||
            currentWrite > writeBuffer.byteLength) {
            throw new Error('PDF 暂存写入失败')
          }
          written += currentWrite
        }
        totalCopied = nextTotal
      }
      const extraBuffer: ArrayBuffer = new ArrayBuffer(1)
      const extraBytes: number = await fs.read(sourceFd, extraBuffer)
      if (extraBytes !== 0 || totalCopied !== expectedSize) {
        throw new Error('PDF 文件在读取期间发生变化')
      }
      await fs.fsync(targetFile.fd)
    } finally {
      await fs.close(targetFile)
    }
  }

  private async removeStagedPdf(cacheDir: string, path: string): Promise<void> {
    const prefix: string = cacheDir + '/cloud_import_pdf_'
    if (!path.startsWith(prefix) || !path.endsWith('.pdf') || path.indexOf('\\') >= 0 ||
      path.substring(cacheDir.length + 1).indexOf('/') >= 0) {
      throw new Error('PDF 临时文件路径无效')
    }
    const info: fs.Stat | null = await this.lstatIfPresent(path)
    if (info === null) {
      return
    }
    if (info.isSymbolicLink() || !info.isFile()) {
      throw new Error('PDF 临时文件类型无效')
    }
    await fs.unlink(path)
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

  private resolveFileName(uri: string, fallback: string): string {
    let encodedName: string = fallback
    if (encodedName.length === 0) {
      const slashIndex: number = uri.lastIndexOf('/')
      encodedName = slashIndex >= 0 ? uri.substring(slashIndex + 1) : 'selected.pdf'
    }
    const queryIndex: number = encodedName.indexOf('?')
    if (queryIndex >= 0) {
      encodedName = encodedName.substring(0, queryIndex)
    }
    try {
      const decodedName: string = decodeURIComponent(encodedName)
      return decodedName.length > 0 ? decodedName : 'selected.pdf'
    } catch {
      return fallback.length > 0 ? fallback : 'selected.pdf'
    }
  }

  private messageForPdfError(err: Error): string {
    let message: string = ''
    if (err instanceof Error) {
      message = err.message
    }
    if (message.includes('已有 PDF 选择任务')) {
      return '正在选择 PDF，请稍候'
    }
    if (message.includes('大小') || message.includes('超过限制')) {
      return 'PDF 文件不能超过 200 MB'
    }
    if (message.includes('暂存') || message.includes('空间')) {
      return 'PDF 暂存失败，请检查本地空间'
    }
    if (message.includes('选择') || message.includes('picker')) {
      return 'PDF 导入失败，请重新选择文件'
    }
    return 'PDF 导入失败，请重新选择文件'
  }

  build() {
    Column() {
      AppHeader({
        title: '导入题库',
        showBack: true,
        onBack: () => {
          this.goBack()
        }
      })

      Scroll() {
        Column({ space: 18 }) {
          Column({ space: 14 }) {
            Row() {
              Text('JSON 格式说明')
                .fontSize(SUBTITLE_FONT_SIZE)
                .fontWeight(FontWeight.Bold)
                .fontColor(COLOR_TEXT_PRIMARY)

              Blank()

              Text('仅支持单选题')
                .fontSize(12)
                .fontColor(COLOR_PRIMARY)
            }
            .width('100%')

            Text('文件需要包含题库名称 bankName、学科 subject 和题目数组 questions。每道题需包含 id、type、question、options、answer 与 analysis。')
              .width('100%')
              .fontSize(BODY_FONT_SIZE)
              .fontColor(COLOR_TEXT_CAPTION)
              .lineHeight(22)

            Text('type 请填写 single_choice，answer 使用与选项对应的字母。文件编码需为 UTF-8。')
              .width('100%')
              .fontSize(BODY_FONT_SIZE)
              .fontColor(COLOR_TEXT_CAPTION)
              .lineHeight(22)
          }
          .width('100%')
          .padding(20)
          .backgroundColor(COLOR_CARD_BG)
          .borderRadius(CARD_RADIUS)

          if (this.importing) {
            Row({ space: 12 }) {
              LoadingProgress()
                .width(24)
                .height(24)
                .color(COLOR_PRIMARY)

              Text('正在读取并导入题库…')
                .fontSize(BODY_FONT_SIZE)
                .fontColor(COLOR_TEXT_CAPTION)
            }
            .width('100%')
            .height(56)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(COLOR_CARD_BG)
            .borderRadius(16)
          }

          if (this.errorMessage.length > 0) {
            Text(this.errorMessage)
              .width('100%')
              .constraintSize({ minHeight: 48 })
              .padding({ left: 16, right: 16, top: 13, bottom: 13 })
              .fontSize(BODY_FONT_SIZE)
              .fontColor(COLOR_DANGER)
              .backgroundColor('#FFF2F2')
              .borderRadius(14)
              .accessibilityText('导入失败：' + this.errorMessage)
          }

          Button() {
            Text(this.importing ? '正在导入…' : '选择 JSON 文件')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
          }
          .type(ButtonType.Normal)
          .width('100%')
          .height(52)
          .backgroundColor(COLOR_PRIMARY)
          .borderRadius(16)
          .enabled(!this.importing && !this.pdfSelecting)
          .accessibilityText(this.importing ? '正在导入题库' : '选择 JSON 文件')
          .onClick(() => {
            this.startImport()
          })

          Button() {
            Text(this.pdfSelecting ? '正在选择…' : '导入 PDF')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLOR_PRIMARY)
          }
          .type(ButtonType.Normal)
          .width('100%')
          .height(52)
          .backgroundColor(COLOR_CARD_BG)
          .border({ width: 1, color: COLOR_PRIMARY })
          .borderRadius(16)
          .enabled(!this.pdfSelecting && !this.importing)
          .accessibilityText(this.pdfSelecting ? '正在选择 PDF' : '导入 PDF')
          .onClick(() => {
            this.selectPdf()
          })
        }
        .width('100%')
        .padding({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: PAGE_PADDING })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR_PAGE_BG)
  }
}
