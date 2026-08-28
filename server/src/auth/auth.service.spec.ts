import { JwtService } from '@nestjs/jwt';
import { UnauthorizedException } from '@nestjs/common';
import {
  AccountStore,
  DeviceRecord,
  DeviceSessionStore,
  HuaweiIdentityProvider,
  StoredHuaweiIdentity,
  UserRecord
} from './auth.contracts';
import { AuthService } from './auth.service';
import { TokenService } from './token.service';
import { IdentityProtector } from '../security/identity-protector';

class FakeHuaweiIdentityProvider implements HuaweiIdentityProvider {
  calls = 0;

  async exchangeAuthorizationCode(): Promise<{ unionId: string; openId: string | null }> {
    this.calls += 1;
    return { unionId: 'plain-union-id', openId: 'plain-open-id' };
  }
}

class InMemoryAccountStore implements AccountStore {
  identity: StoredHuaweiIdentity | null = null;

  async findOrCreateHuaweiUser(identity: StoredHuaweiIdentity): Promise<UserRecord> {
    this.identity = identity;
    return { id: 'user-1' };
  }
}

class InMemoryDeviceSessionStore implements DeviceSessionStore {
  currentHash: string | null = null;
  revoked = false;

  async registerDevice(userId: string, deviceKey: string, deviceName: string): Promise<DeviceRecord> {
    return {
      id: `${userId}:${deviceKey}`,
      name: deviceName,
      sessionGeneration: 'generation-1'
    };
  }

  async replaceRefreshToken(
    _userId: string,
    _deviceId: string,
    sessionGeneration: string,
    refreshTokenHash: string
  ): Promise<boolean> {
    if (sessionGeneration !== 'generation-1') {
      return false;
    }
    this.currentHash = refreshTokenHash;
    this.revoked = false;
    return true;
  }

  async rotateRefreshToken(
    _userId: string,
    _deviceId: string,
    sessionGeneration: string,
    previousRefreshTokenHash: string,
    nextRefreshTokenHash: string
  ): Promise<boolean> {
    if (
      sessionGeneration !== 'generation-1' ||
      this.revoked ||
      this.currentHash !== previousRefreshTokenHash
    ) {
      return false;
    }
    this.currentHash = nextRefreshTokenHash;
    return true;
  }

  async revokeDeviceWithRefreshToken(
    _userId: string,
    _deviceId: string,
    sessionGeneration: string,
    refreshTokenHash: string
  ): Promise<boolean> {
    if (
      sessionGeneration !== 'generation-1' ||
      this.revoked ||
      this.currentHash !== refreshTokenHash
    ) {
      return false;
    }
    this.revoked = true;
    return true;
  }

  async isDeviceActive(): Promise<boolean> {
    return !this.revoked;
  }
}

describe('AuthService', () => {
  const encryptionKey =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const accessSecret = 'access-secret-with-at-least-32-characters';
  const refreshSecret = 'refresh-secret-with-at-least-32-characters';

  function createSubject() {
    const huawei = new FakeHuaweiIdentityProvider();
    const accounts = new InMemoryAccountStore();
    const sessions = new InMemoryDeviceSessionStore();
    const tokenService = new TokenService(new JwtService(), accessSecret, refreshSecret);
    return {
      huawei,
      accounts,
      sessions,
      tokenService,
      service: new AuthService(
        huawei,
        new IdentityProtector(encryptionKey),
        accounts,
        sessions,
        tokenService
      )
    };
  }

  it('creates a user session without persisting plaintext Huawei identifiers', async () => {
    const subject = createSubject();

    const result = await subject.service.loginWithHuawei({
      authorizationCode: 'authorization-code',
      deviceKey: 'device-key-1',
      deviceName: 'WEB-W00'
    });

    expect(result.userId).toBe('user-1');
    expect(result.accessToken.length).toBeGreaterThan(20);
    expect(result.refreshToken.length).toBeGreaterThan(20);
    expect(subject.accounts.identity?.unionIdHash).toHaveLength(64);
    expect(subject.accounts.identity?.encryptedUnionId).not.toContain('plain-union-id');
    expect(subject.accounts.identity?.encryptedOpenId).not.toContain('plain-open-id');
    expect(subject.sessions.currentHash).toHaveLength(64);
  });

  it('rotates an active refresh token', async () => {
    const subject = createSubject();
    const login = await subject.service.loginWithHuawei({
      authorizationCode: 'authorization-code',
      deviceKey: 'device-key-1',
      deviceName: 'WEB-W00'
    });
    const previousHash = subject.sessions.currentHash;

    const refreshed = await subject.service.refresh(login.refreshToken);

    expect(refreshed.refreshToken).not.toBe(login.refreshToken);
    expect(subject.sessions.currentHash).not.toBe(previousHash);
  });

  it('rejects a refresh token after its device is revoked', async () => {
    const subject = createSubject();
    const login = await subject.service.loginWithHuawei({
      authorizationCode: 'authorization-code',
      deviceKey: 'device-key-1',
      deviceName: 'WEB-W00'
    });
    await subject.service.logout(login.refreshToken);

    await expect(subject.service.refresh(login.refreshToken)).rejects.toBeInstanceOf(
      UnauthorizedException
    );
  });

  it('allows a refresh token to be consumed only once', async () => {
    const subject = createSubject();
    const login = await subject.service.loginWithHuawei({
      authorizationCode: 'authorization-code',
      deviceKey: 'device-key-1',
      deviceName: 'WEB-W00'
    });

    await expect(subject.service.refresh(login.refreshToken)).resolves.toBeDefined();
    await expect(subject.service.refresh(login.refreshToken)).rejects.toBeInstanceOf(
      UnauthorizedException
    );
  });

  it('does not let an already rotated refresh token revoke the device', async () => {
    const subject = createSubject();
    const login = await subject.service.loginWithHuawei({
      authorizationCode: 'authorization-code',
      deviceKey: 'device-key-1',
      deviceName: 'WEB-W00'
    });
    await subject.service.refresh(login.refreshToken);

    await expect(subject.service.logout(login.refreshToken)).rejects.toBeInstanceOf(
      UnauthorizedException
    );
    expect(subject.sessions.revoked).toBe(false);
  });
});
