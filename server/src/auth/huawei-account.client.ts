import { Inject, Injectable, UnauthorizedException } from '@nestjs/common';
import { FORM_HTTP_CLIENT, FormHttpClient } from '../http/form-http-client';

export const HUAWEI_CLIENT_ID = Symbol('HUAWEI_CLIENT_ID');
export const HUAWEI_CLIENT_SECRET = Symbol('HUAWEI_CLIENT_SECRET');
export const HUAWEI_TOKEN_URL = Symbol('HUAWEI_TOKEN_URL');
export const HUAWEI_PROFILE_URL = Symbol('HUAWEI_PROFILE_URL');

export interface HuaweiIdentity {
  unionId: string;
  openId: string | null;
}

function readString(body: Record<string, unknown>, keys: string[]): string | null {
  for (const key of keys) {
    const value = body[key];
    if (typeof value === 'string' && value.length > 0) {
      return value;
    }
  }
  return null;
}

@Injectable()
export class HuaweiAccountClient {
  constructor(
    @Inject(FORM_HTTP_CLIENT) private readonly http: FormHttpClient,
    @Inject(HUAWEI_CLIENT_ID) private readonly clientId: string,
    @Inject(HUAWEI_CLIENT_SECRET) private readonly clientSecret: string,
    @Inject(HUAWEI_TOKEN_URL) private readonly tokenUrl: string,
    @Inject(HUAWEI_PROFILE_URL) private readonly profileUrl: string
  ) {}

  async exchangeAuthorizationCode(code: string): Promise<HuaweiIdentity> {
    const tokenResponse = await this.http.postForm(
      this.tokenUrl,
      new URLSearchParams({
        grant_type: 'authorization_code',
        code,
        client_id: this.clientId,
        client_secret: this.clientSecret
      })
    );
    const accessToken = readString(tokenResponse.body, ['access_token', 'accessToken']);
    if (tokenResponse.status < 200 || tokenResponse.status >= 300 || accessToken === null) {
      throw new UnauthorizedException('Huawei authorization failed');
    }

    const profileResponse = await this.http.postForm(
      this.profileUrl,
      new URLSearchParams({ access_token: accessToken, open_id: 'OPENID' })
    );
    const unionId = readString(profileResponse.body, ['union_id', 'unionID', 'unionId']);
    if (profileResponse.status < 200 || profileResponse.status >= 300 || unionId === null) {
      throw new UnauthorizedException('Huawei identity verification failed');
    }
    return {
      unionId,
      openId: readString(profileResponse.body, ['open_id', 'openID', 'openId'])
    };
  }
}
