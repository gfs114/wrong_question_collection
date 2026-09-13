import { BusinessError } from '@kit.BasicServicesKit'
import { http } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import { AiImportLimits } from '../../constants/AiImportLimits'
import { AiImportError, AiImportErrorCode, AiProviderConfigValidator } from '../../models/ai/AiProviderConfig'
import { Utf8Utils } from '../../utils/Utf8Utils'

interface AiRequestHeaders {
  'Content-Type': string
  'Accept': string
  'Authorization': string
}

export interface AiVisionTransportPort {
  postJson(endpoint: string, credential: Uint8Array, jsonBody: string, requestKey: string): Promise<string>
  cancel(requestKey: string): void
}

export class AiCredentialHeaderValidator {
  static decode(credential: Uint8Array): string {
    if (credential.length === 0) {
      throw new AiImportError(AiImportErrorCode.MISSING_API_KEY)
    }
    let credentialText: string = ''
    try {
      credentialText = Utf8Utils.decode(credential)
    } catch {
      throw new AiImportError(AiImportErrorCode.MISSING_API_KEY)
    }
    if (credentialText.length === 0) {
      throw new AiImportError(AiImportErrorCode.MISSING_API_KEY)
    }
    for (let index: number = 0; index < credentialText.length; index++) {
      const code: number = credentialText.charCodeAt(index)
      if (code <= 0x1F || code === 0x7F) {
        throw new AiImportError(AiImportErrorCode.MISSING_API_KEY)
      }
    }
    return credentialText
  }
}

export class AiTransportErrorMapper {
  static status(status: number): AiImportError | null {
    if (status >= 200 && status < 300) return null
    if (status === 401 || status === 403) return new AiImportError(AiImportErrorCode.AUTH_FAILED)
    if (status === 404) return new AiImportError(AiImportErrorCode.ENDPOINT_OR_MODEL_NOT_FOUND)
    if (status === 429) return new AiImportError(AiImportErrorCode.RATE_LIMITED)
    if (status >= 500) return new AiImportError(AiImportErrorCode.PROVIDER_UNAVAILABLE)
    return new AiImportError(AiImportErrorCode.INVALID_JSON)
  }

  static system(code: number, cancelled: boolean): AiImportError {
    if (cancelled) return new AiImportError(AiImportErrorCode.CANCELLED)
    if (code === 2300028) return new AiImportError(AiImportErrorCode.TIMEOUT)
    if (code === 2300063) return new AiImportError(AiImportErrorCode.RESPONSE_TOO_LARGE)
    if (code === 2300058 || code === 2300059 || code === 2300060 || code === 2300077) {
      return new AiImportError(AiImportErrorCode.TLS_FAILED)
    }
    return new AiImportError(AiImportErrorCode.NETWORK_UNAVAILABLE)
  }
}

class AiActiveRequestState {
  private request: http.HttpRequest
  cancelled: boolean = false
  private destroyed: boolean = false

  constructor(request: http.HttpRequest) {
    this.request = request
  }

  cancel(): void {
    this.cancelled = true
    this.destroyOnce()
  }

  destroyOnce(): void {
    if (this.destroyed) return
    this.destroyed = true
    this.request.destroy()
  }
}

export class AiVisionTransport implements AiVisionTransportPort {
  private activeRequests: Map<string, http.HttpRequest> = new Map<string, http.HttpRequest>()
  private requestStates: Map<http.HttpRequest, AiActiveRequestState> =
    new Map<http.HttpRequest, AiActiveRequestState>()

  async postJson(endpoint: string, credential: Uint8Array, jsonBody: string,
    requestKey: string): Promise<string> {
    // 仅 https 或本机/私网 http（明文会把 Bearer 暴露在局域网内，故白名单与 UI 风险提示同时生效）
    if (!AiProviderConfigValidator.isAllowedEndpoint(endpoint)) {
      throw new AiImportError(AiImportErrorCode.INVALID_BASE_URL)
    }
    const bodyBytes: Uint8Array = new util.TextEncoder('utf-8').encodeInto(jsonBody)
    let credentialText: string = ''
    const headers: AiRequestHeaders = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Authorization': ''
    }
    try {
      if (bodyBytes.length > AiImportLimits.MAX_REQUEST_BYTES) {
        throw new AiImportError(AiImportErrorCode.RESPONSE_TOO_LARGE)
      }
      credentialText = AiCredentialHeaderValidator.decode(credential)
      headers.Authorization = 'Bearer ' + credentialText
      const request: http.HttpRequest = http.createHttp()
      const state: AiActiveRequestState = new AiActiveRequestState(request)
      try {
        this.requestStates.set(request, state)
        const previousRequest: http.HttpRequest | undefined = this.activeRequests.get(requestKey)
        if (previousRequest !== undefined) {
          const previousState: AiActiveRequestState | undefined = this.requestStates.get(previousRequest)
          if (previousState !== undefined) previousState.cancel()
        }
        this.activeRequests.set(requestKey, request)
        const options: http.HttpRequestOptions = {
          method: http.RequestMethod.POST,
          header: headers,
          extraData: jsonBody,
          connectTimeout: AiImportLimits.CONNECT_TIMEOUT_MS,
          readTimeout: AiImportLimits.READ_TIMEOUT_MS,
          expectDataType: http.HttpDataType.STRING,
          usingCache: false,
          maxLimit: AiImportLimits.MAX_RESPONSE_BYTES,
          maxRedirects: 0
        }
        const response: http.HttpResponse = await request.request(endpoint, options)
          .catch((error: BusinessError): http.HttpResponse => {
            throw AiTransportErrorMapper.system(error.code, state.cancelled)
          })
        if (state.cancelled) {
          throw new AiImportError(AiImportErrorCode.CANCELLED)
        }
        const statusError: AiImportError | null = AiTransportErrorMapper.status(response.responseCode)
        if (statusError !== null) throw statusError
        const contentType: string = AiVisionTransport.contentType(response.header)
        if (!/^application\/json(?:\s*;|$)/i.test(contentType)) {
          throw new AiImportError(AiImportErrorCode.INVALID_CONTENT_TYPE)
        }
        const raw: string = String(response.result)
        if (new util.TextEncoder('utf-8').encodeInto(raw).length > AiImportLimits.MAX_RESPONSE_BYTES) {
          throw new AiImportError(AiImportErrorCode.RESPONSE_TOO_LARGE)
        }
        return raw
      } finally {
        if (this.activeRequests.get(requestKey) === request) this.activeRequests.delete(requestKey)
        this.requestStates.delete(request)
        state.destroyOnce()
      }
    } finally {
      headers.Authorization = ''
      credentialText = ''
      bodyBytes.fill(0)
    }
  }

  async getJson(endpoint: string, credential: Uint8Array, requestKey: string): Promise<string> {
    if (!AiProviderConfigValidator.isAllowedEndpoint(endpoint)) {
      throw new AiImportError(AiImportErrorCode.INVALID_BASE_URL)
    }
    let credentialText: string = ''
    const headers: AiRequestHeaders = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Authorization': ''
    }
    try {
      credentialText = AiCredentialHeaderValidator.decode(credential)
      headers.Authorization = 'Bearer ' + credentialText
      const request: http.HttpRequest = http.createHttp()
      const state: AiActiveRequestState = new AiActiveRequestState(request)
      try {
        this.requestStates.set(request, state)
        const previousRequest: http.HttpRequest | undefined = this.activeRequests.get(requestKey)
        if (previousRequest !== undefined) {
          const previousState: AiActiveRequestState | undefined = this.requestStates.get(previousRequest)
          if (previousState !== undefined) previousState.cancel()
        }
        this.activeRequests.set(requestKey, request)
        const options: http.HttpRequestOptions = {
          method: http.RequestMethod.GET,
          header: headers,
          connectTimeout: AiImportLimits.CONNECT_TIMEOUT_MS,
          readTimeout: AiImportLimits.READ_TIMEOUT_MS,
          expectDataType: http.HttpDataType.STRING,
          usingCache: false,
          maxLimit: AiImportLimits.MAX_RESPONSE_BYTES,
          maxRedirects: 0
        }
        const response: http.HttpResponse = await request.request(endpoint, options)
          .catch((error: BusinessError): http.HttpResponse => {
            throw AiTransportErrorMapper.system(error.code, state.cancelled)
          })
        if (state.cancelled) throw new AiImportError(AiImportErrorCode.CANCELLED)
        const statusError: AiImportError | null = AiTransportErrorMapper.status(response.responseCode)
        if (statusError !== null) throw statusError
        const contentType: string = AiVisionTransport.contentType(response.header)
        if (!/^application\/json(?:\s*;|$)/i.test(contentType)) {
          throw new AiImportError(AiImportErrorCode.INVALID_CONTENT_TYPE)
        }
        const raw: string = String(response.result)
        if (new util.TextEncoder('utf-8').encodeInto(raw).length > AiImportLimits.MAX_RESPONSE_BYTES) {
          throw new AiImportError(AiImportErrorCode.RESPONSE_TOO_LARGE)
        }
        return raw
      } finally {
        if (this.activeRequests.get(requestKey) === request) this.activeRequests.delete(requestKey)
        this.requestStates.delete(request)
        state.destroyOnce()
      }
    } finally {
      headers.Authorization = ''
      credentialText = ''
    }
  }

  cancel(requestKey: string): void {
    const request: http.HttpRequest | undefined = this.activeRequests.get(requestKey)
    if (request === undefined) return
    const state: AiActiveRequestState | undefined = this.requestStates.get(request)
    if (state === undefined) return
    state.cancel()
  }

  private static contentType(header: Object): string {
    const serialized: string = JSON.stringify(header)
    const match: RegExpMatchArray | null = serialized.match(
      /"content-type"\s*:\s*(?:"([^"]*)"|\[\s*"([^"]*)")/i)
    if (match === null) return ''
    if (match[1] !== undefined) return match[1]
    return match[2] === undefined ? '' : match[2]
  }
}
