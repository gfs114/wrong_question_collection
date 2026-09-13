import { AiProviderConfig } from '../../models/ai/AiProviderConfig'

export class AiProviderRequest {
  endpoint: string
  body: string

  constructor(endpoint: string, body: string) {
    this.endpoint = endpoint
    this.body = body
  }

  release(): void {
    this.body = ''
  }
}

export interface AiProviderAdapter {
  buildRequest(config: AiProviderConfig, prompt: string, jpegBase64: string): AiProviderRequest
  extractAssistantContent(response: string): string
}
