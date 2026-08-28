import { Inject, Injectable, UnauthorizedException } from '@nestjs/common';
import {
  ACCOUNT_STORE,
  AccountStore,
  DEVICE_SESSION_STORE,
  DeviceSessionStore,
  HUAWEI_IDENTITY_PROVIDER,
  HuaweiIdentityProvider,
  IDENTITY_PROTECTOR
} from './auth.contracts';
import { IdentityProtector } from '../security/identity-protector';
import { SessionTokens, TokenService } from './token.service';

export interface HuaweiLoginRequest {
  authorizationCode: string;
  deviceKey: string;
  deviceName: string;
}

export interface LoginResult extends SessionTokens {
  userId: string;
  deviceId: string;
}

@Injectable()
export class AuthService {
  constructor(
    @Inject(HUAWEI_IDENTITY_PROVIDER)
    private readonly huaweiIdentityProvider: HuaweiIdentityProvider,
    @Inject(IDENTITY_PROTECTOR)
    private readonly identityProtector: IdentityProtector,
    @Inject(ACCOUNT_STORE)
    private readonly accountStore: AccountStore,
    @Inject(DEVICE_SESSION_STORE)
    private readonly sessionStore: DeviceSessionStore,
    private readonly tokenService: TokenService
  ) {}

  async loginWithHuawei(request: HuaweiLoginRequest): Promise<LoginResult> {
    const identity = await this.huaweiIdentityProvider.exchangeAuthorizationCode(
      request.authorizationCode
    );
    const user = await this.accountStore.findOrCreateHuaweiUser({
      unionIdHash: this.identityProtector.digest(identity.unionId),
      encryptedUnionId: this.identityProtector.encrypt(identity.unionId),
      encryptedOpenId:
        identity.openId === null ? null : this.identityProtector.encrypt(identity.openId)
    });
    const device = await this.sessionStore.registerDevice(
      user.id,
      request.deviceKey,
      request.deviceName
    );
    const tokens = await this.tokenService.issue(
      user.id,
      device.id,
      device.sessionGeneration
    );
    const installed = await this.sessionStore.replaceRefreshToken(
      user.id,
      device.id,
      device.sessionGeneration,
      this.tokenService.hashRefreshToken(tokens.refreshToken)
    );
    if (!installed) {
      throw new UnauthorizedException('A newer login replaced this device session');
    }
    return {
      userId: user.id,
      deviceId: device.id,
      ...tokens
    };
  }

  async refresh(refreshToken: string): Promise<SessionTokens> {
    const verified = await this.tokenService.verifyRefresh(refreshToken);
    const tokens = await this.tokenService.issue(
      verified.userId,
      verified.deviceId,
      verified.sessionGeneration
    );
    const rotated = await this.sessionStore.rotateRefreshToken(
      verified.userId,
      verified.deviceId,
      verified.sessionGeneration,
      this.tokenService.hashRefreshToken(refreshToken),
      this.tokenService.hashRefreshToken(tokens.refreshToken)
    );
    if (!rotated) {
      throw new UnauthorizedException('Refresh token is no longer active');
    }
    return tokens;
  }

  async logout(refreshToken: string): Promise<void> {
    const verified = await this.tokenService.verifyRefresh(refreshToken);
    const revoked = await this.sessionStore.revokeDeviceWithRefreshToken(
      verified.userId,
      verified.deviceId,
      verified.sessionGeneration,
      this.tokenService.hashRefreshToken(refreshToken)
    );
    if (!revoked) {
      throw new UnauthorizedException('Refresh token is no longer active');
    }
  }
}
