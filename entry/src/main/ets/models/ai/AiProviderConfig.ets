import url from '@ohos.url'

export class AiProviderId {
  static readonly OPENAI: string = 'openai'
  static readonly CUSTOM: string = 'openai_compatible'
}

export enum AiImportErrorCode {
  CREDENTIAL_UPDATE_PENDING = 'CREDENTIAL_UPDATE_PENDING',
  CONFIG_NOT_SAVED = 'CONFIG_NOT_SAVED',
  REPLACEMENT_KEY_REQUIRED = 'REPLACEMENT_KEY_REQUIRED',
  INVALID_BASE_URL = 'INVALID_BASE_URL',
  MISSING_API_KEY = 'MISSING_API_KEY',
  MISSING_MODEL = 'MISSING_MODEL',
  NETWORK_UNAVAILABLE = 'NETWORK_UNAVAILABLE',
  TLS_FAILED = 'TLS_FAILED',
  AUTH_FAILED = 'AUTH_FAILED',
  ENDPOINT_OR_MODEL_NOT_FOUND = 'ENDPOINT_OR_MODEL_NOT_FOUND',
  RATE_LIMITED = 'RATE_LIMITED',
  PROVIDER_UNAVAILABLE = 'PROVIDER_UNAVAILABLE',
  TIMEOUT = 'TIMEOUT',
  RESPONSE_TOO_LARGE = 'RESPONSE_TOO_LARGE',
  INVALID_CONTENT_TYPE = 'INVALID_CONTENT_TYPE',
  INVALID_JSON = 'INVALID_JSON',
  NO_QUESTIONS = 'NO_QUESTIONS',
  LATEX_INVALID = 'LATEX_INVALID',
  CANCELLED = 'CANCELLED'
}

export class AiImportErrorMessages {
  static forCode(code: AiImportErrorCode): string {
    if (code === AiImportErrorCode.CREDENTIAL_UPDATE_PENDING) return '密钥更新未完成，请重新输入 API Key 并保存，或清除 API Key'
    if (code === AiImportErrorCode.CONFIG_NOT_SAVED) return '请先保存当前 AI 配置，再测试连接'
    if (code === AiImportErrorCode.REPLACEMENT_KEY_REQUIRED) return 'AI 配置已更改，请重新输入 API Key 并保存'
    if (code === AiImportErrorCode.INVALID_BASE_URL) return 'AI 服务地址无效，仅支持 HTTPS 或本机/私网 HTTP'
    if (code === AiImportErrorCode.MISSING_API_KEY) return '请先配置 API Key'
    if (code === AiImportErrorCode.MISSING_MODEL) return '请填写模型名称'
    if (code === AiImportErrorCode.NETWORK_UNAVAILABLE) return '当前网络不可用'
    if (code === AiImportErrorCode.TLS_FAILED) return '无法建立安全连接，请检查服务地址或证书'
    if (code === AiImportErrorCode.AUTH_FAILED) return 'API Key 或权限不可用'
    if (code === AiImportErrorCode.ENDPOINT_OR_MODEL_NOT_FOUND) return '接口地址或模型不可用'
    if (code === AiImportErrorCode.RATE_LIMITED) return '请求过于频繁或额度不足，请稍后重试'
    if (code === AiImportErrorCode.PROVIDER_UNAVAILABLE) return 'AI 服务暂时不可用'
    if (code === AiImportErrorCode.TIMEOUT) return 'AI 识别超时'
    if (code === AiImportErrorCode.RESPONSE_TOO_LARGE) return 'AI 返回内容超过限制'
    if (code === AiImportErrorCode.INVALID_CONTENT_TYPE) return 'AI 返回格式不是 JSON'
    if (code === AiImportErrorCode.NO_QUESTIONS) return '本页未识别到题目'
    if (code === AiImportErrorCode.LATEX_INVALID) return '数学公式结构不完整'
    if (code === AiImportErrorCode.CANCELLED) return '本次识别已取消'
    return 'AI 返回的 JSON 无法解析或不符合格式'
  }
}

export class AiImportError extends Error {
  readonly code: AiImportErrorCode

  constructor(code: AiImportErrorCode) {
    super(AiImportErrorMessages.forCode(code))
    this.name = 'AiImportError'
    this.code = code
  }
}

export class AiProviderConfig {
  providerId: string
  model: string
  baseUrl: string
  supportsStructuredOutput: boolean

  constructor(providerId: string, model: string, baseUrl: string,
    supportsStructuredOutput: boolean = false) {
    this.providerId = providerId
    this.model = model
    this.baseUrl = baseUrl
    this.supportsStructuredOutput = supportsStructuredOutput
  }
}

export class AiProviderConfigValidator {
  static openAiDefault(): AiProviderConfig {
    return new AiProviderConfig(AiProviderId.OPENAI, '', 'https://api.openai.com/v1', true)
  }

  private static isLocalOrPrivateHost(hostname: string): boolean {
    const host: string = hostname.trim().toLowerCase()
      .replace(/^\[|\]$/g, '')
    if (host === 'localhost' || host === '::1') return true
    const octets: Array<string> = host.split('.')
    if (octets.length !== 4) return false
    for (let index: number = 0; index < octets.length; index++) {
      const octet: string = octets[index]
      if (octet.length === 0 || octet.length > 3) return false
      for (let digit: number = 0; digit < octet.length; digit++) {
        const code: number = octet.charCodeAt(digit)
        if (code < 48 || code > 57) return false
      }
      if (Number.parseInt(octet, 10) > 255) return false
    }
    const first: number = Number.parseInt(octets[0], 10)
    const second: number = Number.parseInt(octets[1], 10)
    if (first === 127 || first === 10) return true
    if (first === 192 && second === 168) return true
    return first === 172 && second >= 16 && second <= 31
  }

  // 端点守卫：**只判定 scheme + host**（https 一律放行；http 仅限本机/私网白名单）。
  // userinfo / query / hash / `/chat/completions` 路径规则由 normalize() 负责，
  // 因此任何调用方都必须先把端点交给 AiProviderConfigStore 审核后再传进来。
  static isAllowedEndpoint(rawEndpoint: string): boolean {
    let parsed: url.URL
    try {
      parsed = url.URL.parseURL(rawEndpoint.trim())
    } catch {
      return false
    }
    const protocol: string = parsed.protocol.toLowerCase()
    if (protocol === 'https:') return true
    return protocol === 'http:' &&
      AiProviderConfigValidator.isLocalOrPrivateHost(parsed.hostname)
  }

  static normalize(input: AiProviderConfig): AiProviderConfig {
    const model: string = input.model.trim()
    if (model.length === 0 || model.length > 200) {
      throw new AiImportError(AiImportErrorCode.MISSING_MODEL)
    }
    const baseUrl: string = AiProviderConfigValidator.normalizeBaseUrl(input.baseUrl)
    return new AiProviderConfig(input.providerId, model, baseUrl,
      input.providerId === AiProviderId.OPENAI)
  }

  // 模型发现发生在用户选择模型之前，因此只验证服务地址，不要求先存在 model。
  // 路径、scheme、私网 HTTP 与 userinfo/query/hash 规则和正式配置共用这一入口。
  static normalizeBaseUrl(input: string): string {
    const rawBaseUrl: string = input.trim()
    let parsed: url.URL
    try {
      parsed = url.URL.parseURL(rawBaseUrl)
    } catch {
      throw new AiImportError(AiImportErrorCode.INVALID_BASE_URL)
    }
    // 端点白名单与传输层共用同一谓词，避免两处判断漂移；userinfo/query/hash 等既有规则在下方继续生效。
    if (!AiProviderConfigValidator.isAllowedEndpoint(rawBaseUrl)) {
      throw new AiImportError(AiImportErrorCode.INVALID_BASE_URL)
    }
    if (parsed.hostname.length === 0 ||
      parsed.username.length > 0 || parsed.password.length > 0 ||
      parsed.search.length > 0 || parsed.hash.length > 0) {
      throw new AiImportError(AiImportErrorCode.INVALID_BASE_URL)
    }
    let path: string = parsed.pathname
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1)
    }
    const lowerPath: string = path.toLowerCase()
    if (lowerPath.endsWith('/chat/completions') || lowerPath.endsWith('/models')) {
      throw new AiImportError(AiImportErrorCode.INVALID_BASE_URL)
    }
    const normalizedPath: string = path === '/' ? '' : path
    return parsed.origin + normalizedPath
  }
}
