import { UnauthorizedException } from '@nestjs/common';
import {
  FormHttpClient,
  FormHttpResponse
} from '../http/form-http-client';
import { HuaweiAccountClient } from './huawei-account.client';

class RecordingHttpClient implements FormHttpClient {
  readonly calls: Array<{ method: string; url: string; body?: URLSearchParams; token?: string }> = [];
  tokenResponse: FormHttpResponse = {
    status: 200,
    body: { access_token: 'huawei-access-token' }
  };
  profileResponse: FormHttpResponse = {
    status: 200,
    body: { union_id: 'union-id-1', open_id: 'open-id-1' }
  };

  async postForm(url: string, body: URLSearchParams): Promise<FormHttpResponse> {
    this.calls.push({ method: 'POST', url, body });
    return url.endsWith('/token') ? this.tokenResponse : this.profileResponse;
  }
}

describe('HuaweiAccountClient', () => {
  it('exchanges an authorization code and returns stable Huawei identifiers', async () => {
    const http = new RecordingHttpClient();
    const client = new HuaweiAccountClient(
      http,
      'client-id',
      'client-secret',
      'https://accounts.example.test/token',
      'https://accounts.example.test/profile'
    );

    await expect(client.exchangeAuthorizationCode('authorization-code')).resolves.toEqual({
      unionId: 'union-id-1',
      openId: 'open-id-1'
    });
    expect(http.calls).toHaveLength(2);
    expect(http.calls[0].body?.get('grant_type')).toBe('authorization_code');
    expect(http.calls[0].body?.get('code')).toBe('authorization-code');
    expect(http.calls[0].body?.get('client_id')).toBe('client-id');
    expect(http.calls[0].body?.get('client_secret')).toBe('client-secret');
    expect(http.calls[1]).toMatchObject({
      method: 'POST',
      url: 'https://accounts.example.test/profile'
    });
    expect(http.calls[1].body?.get('access_token')).toBe('huawei-access-token');
    expect(http.calls[1].body?.get('open_id')).toBe('OPENID');
  });

  it('rejects a profile response without UnionID', async () => {
    const http = new RecordingHttpClient();
    http.profileResponse = { status: 200, body: { open_id: 'open-id-1' } };
    const client = new HuaweiAccountClient(
      http,
      'client-id',
      'client-secret',
      'https://accounts.example.test/token',
      'https://accounts.example.test/profile'
    );

    await expect(client.exchangeAuthorizationCode('authorization-code')).rejects.toBeInstanceOf(
      UnauthorizedException
    );
  });

  it('does not expose Huawei response bodies in errors', async () => {
    const http = new RecordingHttpClient();
    http.tokenResponse = {
      status: 401,
      body: { error: 'invalid_grant', access_token: 'sensitive-token' }
    };
    const client = new HuaweiAccountClient(
      http,
      'client-id',
      'client-secret',
      'https://accounts.example.test/token',
      'https://accounts.example.test/profile'
    );

    await expect(client.exchangeAuthorizationCode('authorization-code')).rejects.toThrow(
      'Huawei authorization failed'
    );
    await expect(client.exchangeAuthorizationCode('authorization-code')).rejects.not.toThrow(
      'sensitive-token'
    );
  });
});
