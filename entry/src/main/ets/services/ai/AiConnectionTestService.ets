import { Context } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import {
  AiImportError, AiImportErrorCode, AiProviderConfig, AiProviderConfigValidator
} from '../../models/ai/AiProviderConfig'
import { AiCredentialStore } from './AiCredentialStore'
import { AiProviderConfigStore } from './AiProviderConfigStore'
import { AiProviderAdapter, AiProviderRequest } from './AiProviderAdapter'
import { AiVisionTransport, AiVisionTransportPort } from './AiVisionTransport'
import { OpenAiCompatibleAdapter } from './OpenAiCompatibleAdapter'

const TEST_JPEG_BASE64: string =
  '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD8qqKKKAP/2Q=='

export class AiConnectionTestService {
  private adapter: AiProviderAdapter
  private transport: AiVisionTransportPort

  constructor(adapter: AiProviderAdapter = new OpenAiCompatibleAdapter(),
    transport: AiVisionTransportPort = new AiVisionTransport()) {
    this.adapter = adapter
    this.transport = transport
  }

  async test(context: Context, config: AiProviderConfig): Promise<void> {
    const normalized: AiProviderConfig = AiProviderConfigValidator.normalize(config)
    try {
      await AiProviderConfigStore.withUsableConfig<void>(context, normalized, async (): Promise<void> => {
        await AiCredentialStore.withCredential<void>(context, async (credential: Uint8Array): Promise<void> => {
          await this.testWithCredential(normalized, credential)
        })
      })
    } catch (err) {
      if (err instanceof AiImportError) throw err
      throw new AiImportError(AiImportErrorCode.MISSING_API_KEY)
    }
  }

  async testWithApiKey(config: AiProviderConfig, apiKey: string): Promise<void> {
    let keyText: string = apiKey.trim()
    if (keyText.length === 0) throw new AiImportError(AiImportErrorCode.MISSING_API_KEY)
    const credential: Uint8Array = new util.TextEncoder('utf-8').encodeInto(keyText)
    try {
      await this.testWithCredential(config, credential)
    } finally {
      credential.fill(0)
      keyText = ''
    }
  }

  async testWithCredential(config: AiProviderConfig, credential: Uint8Array): Promise<void> {
    let request: AiProviderRequest | null = null
    let raw: string = ''
    try {
      const normalized: AiProviderConfig = AiProviderConfigValidator.normalize(config)
      if (credential.length === 0) throw new AiImportError(AiImportErrorCode.MISSING_API_KEY)
      request = this.adapter.buildRequest(normalized,
        '这是连接测试图片，无需识别题目。只返回极短 JSON：{"ok":true}。', TEST_JPEG_BASE64)
      const requestKey: string = 'ai-connection-' + util.generateRandomUUID()
      raw = await this.transport.postJson(request.endpoint, credential, request.body, requestKey)
      try {
        if (this.adapter.extractAssistantContent(raw).trim().length === 0) {
          throw new AiImportError(AiImportErrorCode.INVALID_JSON)
        }
      } catch (err) {
        if (err instanceof AiImportError) throw err
        throw new AiImportError(AiImportErrorCode.INVALID_JSON)
      }
    } catch (err) {
      if (err instanceof AiImportError) throw err
      throw new AiImportError(AiImportErrorCode.NETWORK_UNAVAILABLE)
    } finally {
      if (request !== null) request.release()
      raw = ''
    }
  }
}
