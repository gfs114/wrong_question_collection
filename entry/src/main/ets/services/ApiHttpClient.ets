import { http } from '@kit.NetworkKit'
import { ApiConfig } from '../constants/ApiConfig'
import { ApiHttpError } from '../models/ApiModels'

interface JsonRequestHeaders {
  'Content-Type': string
  'Accept': string
  'Authorization'?: string
}

export class ApiHttpClient {
  static async request<T>(method: http.RequestMethod, path: string, body?: object,
    accessToken: string = ''): Promise<T> {
    if (!path.startsWith('/')) {
      throw new ApiHttpError('Invalid API path', 0, 'invalid_path')
    }
    const request: http.HttpRequest = http.createHttp()
    try {
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
      const response: http.HttpResponse = await request.request(ApiConfig.BASE_URL + path, options)
      const raw: string = String(response.result)
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new ApiHttpError('Cloud request failed', response.responseCode, 'http_error')
      }
      if (raw.length === 0) {
        return undefined as T
      }
      try {
        return JSON.parse(raw) as T
      } catch {
        throw new ApiHttpError('Cloud response is invalid', response.responseCode, 'invalid_json')
      }
    } finally {
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
}
