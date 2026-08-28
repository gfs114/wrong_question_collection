import { http } from '@kit.NetworkKit'
import { ApiHttpError } from '../models/ApiModels'
import { ApiHttpClient } from './ApiHttpClient'

export class ApiError extends ApiHttpError {
}

export class ApiClient {
  static async request<T>(method: http.RequestMethod, path: string, body?: object): Promise<T> {
    return ApiHttpClient.request<T>(method, path, body)
  }

  static async get<T>(path: string): Promise<T> {
    return ApiClient.request<T>(http.RequestMethod.GET, path)
  }

  static async post<T>(path: string, body: object): Promise<T> {
    return ApiClient.request<T>(http.RequestMethod.POST, path, body)
  }
}
