import { Context } from '@kit.AbilityKit'
import { fileIo as fs, picker } from '@kit.CoreFileKit'
import { ImportLimits } from '../constants/ImportLimits'
import { ImportResult } from '../models/ImportResult'
import { QuestionBank } from '../models/QuestionBank'
import { JsonParser } from '../utils/JsonParser'
import { Utf8Utils } from '../utils/Utf8Utils'
import { QuestionBankService } from './QuestionBankService'

const READ_CHUNK_BYTES: number = 64 * 1024

export class ImportService {
  static async selectAndImport(context: Context): Promise<ImportResult> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions()
    options.fileSuffixFilters = ['JSON文件|.json']
    options.maxSelectNumber = 1
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context)
    let uris: Array<string> = new Array<string>()
    try {
      uris = await documentPicker.select(options)
    } catch {
      return ImportResult.readError('文件选择失败')
    }
    if (uris.length === 0) {
      return ImportResult.cancelled()
    }

    let text: string = ''
    try {
      text = await ImportService.readUri(uris[0])
    } catch {
      return ImportResult.readError('文件读取失败')
    }

    let bank: QuestionBank
    try {
      bank = JsonParser.parse(text)
    } catch {
      return ImportResult.formatError('题库文件格式不正确')
    }

    try {
      const bankId: string = await QuestionBankService.saveImportedBank(bank, false)
      return ImportResult.success(bankId)
    } catch {
      return ImportResult.saveError('题库保存失败')
    }
  }

  private static async readUri(uri: string): Promise<string> {
    const file: fs.File = await fs.open(uri, fs.OpenMode.READ_ONLY)
    // URI 描述符始终在 finally 中释放。
    try {
      const fileInfo: fs.Stat = await fs.stat(file.fd)
      if (fileInfo.size < 0 || fileInfo.size > ImportLimits.MAX_FILE_BYTES) {
        throw new Error('题库文件大小不正确')
      }
      // 分配前限制文件大小。
      const content: Uint8Array = new Uint8Array(fileInfo.size)
      let totalRead: number = 0
      while (totalRead < fileInfo.size) {
        const remaining: number = fileInfo.size - totalRead
        const chunkSize: number = remaining < READ_CHUNK_BYTES ? remaining : READ_CHUNK_BYTES
        const chunkBuffer: ArrayBuffer = new ArrayBuffer(chunkSize)
        const bytesRead: number = await fs.read(file.fd, chunkBuffer)
        if (bytesRead <= 0 || bytesRead > chunkSize) {
          throw new Error('题库文件读取不完整')
        }
        const chunk: Uint8Array = new Uint8Array(chunkBuffer)
        for (let index: number = 0; index < bytesRead; index++) {
          content[totalRead + index] = chunk[index]
        }
        totalRead += bytesRead
      }
      return Utf8Utils.decode(content)
    } finally {
      await fs.close(file)
    }
  }
}
