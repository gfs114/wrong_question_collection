import { Injectable } from '@nestjs/common';

export const FORM_HTTP_CLIENT = Symbol('FORM_HTTP_CLIENT');

export interface FormHttpResponse {
  status: number;
  body: Record<string, unknown>;
}

export interface FormHttpClient {
  postForm(url: string, body: URLSearchParams): Promise<FormHttpResponse>;
}

function parseJsonRecord(text: string): Record<string, unknown> {
  try {
    const value: unknown = JSON.parse(text);
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      return value as Record<string, unknown>;
    }
  } catch {
    return {};
  }
  return {};
}

@Injectable()
export class FetchFormHttpClient implements FormHttpClient {
  async postForm(url: string, body: URLSearchParams): Promise<FormHttpResponse> {
    const response = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body,
      signal: AbortSignal.timeout(10_000)
    });
    return {
      status: response.status,
      body: parseJsonRecord(await response.text())
    };
  }
}
