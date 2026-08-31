import { http } from '@kit.NetworkKit'
import { ApiConfig } from '../constants/ApiConfig'
import { ApiHttpError } from '../models/ApiModels'

interface JsonRequestHeaders {
  'Content-Type': string
  'Accept': string
  'Authorization'?: string
}

interface BinaryPutHeaders {
  'Content-Type': string
  'Accept': string
  'Authorization': string
  'X-Part-Sha256': string
}

interface BinaryDownloadHeaders {
  'Accept': string
  'Authorization': string
}

export class ApiHttpClient {
  private static activeRequests: Map<string, http.HttpRequest> =
    new Map<string, http.HttpRequest>()

  static async request<T>(method: http.RequestMethod, path: string, body?: object,
    accessToken: string = '', expectedResponseCode: number = 0,
    usingCache: boolean = true, requestKey: string = ''): Promise<T> {
    if (!path.startsWith('/')) {
      throw new ApiHttpError('Invalid API path', 0, 'invalid_path')
    }
    const request: http.HttpRequest = http.createHttp()
    try {
      if (requestKey.length > 0) {
        ApiHttpClient.activeRequests.set(requestKey, request)
      }
      const headers: JsonRequestHeaders = {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      }
      if (accessToken.length > 0) {
        headers.Authorization = 'Bearer ' + accessToken
      }
      const options: http.HttpRequestOptions = {
        method: method,
        header: headers,
        connectTimeout: ApiConfig.CONNECT_TIMEOUT_MS,
        readTimeout: ApiConfig.READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING,
        caPath: ApiConfig.CA_PATH
      }
      if (body !== undefined) {
        options.extraData = JSON.stringify(body)
      }
      if (!usingCache) {
        options.usingCache = false
      }
      const response: http.HttpResponse = await request.request(ApiConfig.BASE_URL + path, options)
      const raw: string = String(response.result)
      const unexpectedCode: boolean = expectedResponseCode > 0 ?
        response.responseCode !== expectedResponseCode :
        response.responseCode < 200 || response.responseCode >= 300
      if (unexpectedCode) {
        throw new ApiHttpError('Cloud request failed', response.responseCode, 'http_error')
      }
      if (response.responseCode === 204 || raw.length === 0) {
        return undefined as T
      }
      try {
        return JSON.parse(raw) as T
      } catch {
        throw new ApiHttpError('Cloud response is invalid', response.responseCode, 'invalid_json')
      }
    } finally {
      ApiHttpClient.releaseRequest(requestKey, request)
      request.destroy()
    }
  }

  static async get<T>(path: string): Promise<T> {
    return ApiHttpClient.request<T>(http.RequestMethod.GET, path)
  }

  static async post<T>(path: string, body: object): Promise<T> {
    return ApiHttpClient.request<T>(http.RequestMethod.POST, path, body)
  }

  static async authorizedGet<T>(path: string, accessToken: string): Promise<T> {
    return ApiHttpClient.request<T>(http.RequestMethod.GET, path, undefined, accessToken)
  }

  static async authorizedPost<T>(path: string, body: object, accessToken: string): Promise<T> {
    return ApiHttpClient.request<T>(http.RequestMethod.POST, path, body, accessToken)
  }

  static async authorizedGetExpecting<T>(path: string, accessToken: string,
    expectedResponseCode: number): Promise<T> {
    return ApiHttpClient.request<T>(http.RequestMethod.GET, path, undefined, accessToken,
      expectedResponseCode, false)
  }

  static async authorizedPostExpecting<T>(path: string, body: object, accessToken: string,
    expectedResponseCode: number, requestKey: string = ''): Promise<T> {
    return ApiHttpClient.request<T>(http.RequestMethod.POST, path, body, accessToken,
      expectedResponseCode, true, requestKey)
  }

  static async authorizedDelete(path: string, accessToken: string,
    expectedResponseCode: number): Promise<void> {
    return ApiHttpClient.request<void>(http.RequestMethod.DELETE, path, undefined, accessToken,
      expectedResponseCode)
  }

  static async authorizedBinaryPut(path: string, body: ArrayBuffer, sha256: string,
    accessToken: string, expectedResponseCode: number, requestKey: string = ''): Promise<void> {
    if (!path.startsWith('/')) {
      throw new ApiHttpError('Invalid API path', 0, 'invalid_path')
    }
    if (accessToken.length === 0) {
      throw new ApiHttpError('Missing access token', 0, 'missing_access_token')
    }
    const request: http.HttpRequest = http.createHttp()
    try {
      if (requestKey.length > 0) {
        ApiHttpClient.activeRequests.set(requestKey, request)
      }
      const headers: BinaryPutHeaders = {
        'Content-Type': 'application/octet-stream',
        'Accept': 'application/json',
        'Authorization': 'Bearer ' + accessToken,
        'X-Part-Sha256': sha256
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.PUT,
        header: headers,
        body: body,
        connectTimeout: ApiConfig.CONNECT_TIMEOUT_MS,
        readTimeout: ApiConfig.READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        caPath: ApiConfig.CA_PATH
      }
      const response: http.HttpResponse = await request.request(ApiConfig.BASE_URL + path, options)
      if (response.responseCode !== expectedResponseCode) {
        throw new ApiHttpError('Cloud request failed', response.responseCode, 'http_error')
      }
    } finally {
      ApiHttpClient.releaseRequest(requestKey, request)
      request.destroy()
    }
  }

  static cancelRequest(requestKey: string): void {
    const request: http.HttpRequest | undefined =
      ApiHttpClient.activeRequests.get(requestKey)
    if (request !== undefined) {
      ApiHttpClient.activeRequests.delete(requestKey)
      request.destroy()
    }
  }

  static async authorizedBinaryDownload(path: string, accessToken: string,
    expectedResponseCode: number, maxResponseBytes: number): Promise<ArrayBuffer> {
    if (!path.startsWith('/')) {
      throw new ApiHttpError('Invalid API path', 0, 'invalid_path')
    }
    if (accessToken.length === 0) {
      throw new ApiHttpError('Missing access token', 0, 'missing_access_token')
    }
    if (!Number.isInteger(maxResponseBytes) || maxResponseBytes <= 0 ||
      maxResponseBytes > 100 * 1024 * 1024) {
      throw new ApiHttpError('Invalid binary response limit', 0, 'invalid_response_limit')
    }
    const request: http.HttpRequest = http.createHttp()
    try {
      const headers: BinaryDownloadHeaders = {
        'Accept': 'image/jpeg',
        'Authorization': 'Bearer ' + accessToken
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: ApiConfig.CONNECT_TIMEOUT_MS,
        readTimeout: ApiConfig.READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: false,
        maxLimit: maxResponseBytes,
        caPath: ApiConfig.CA_PATH
      }
      const response: http.HttpResponse = await request.request(ApiConfig.BASE_URL + path, options)
      if (response.responseCode !== expectedResponseCode) {
        throw new ApiHttpError('Cloud request failed', response.responseCode, 'http_error')
      }
      if (response.result instanceof ArrayBuffer) {
        return response.result
      }
      throw new ApiHttpError('Cloud response is not binary', response.responseCode, 'invalid_binary')
    } finally {
      request.destroy()
    }
  }

  private static releaseRequest(requestKey: string, request: http.HttpRequest): void {
    if (requestKey.length > 0 && ApiHttpClient.activeRequests.get(requestKey) === request) {
      ApiHttpClient.activeRequests.delete(requestKey)
    }
  }
}
