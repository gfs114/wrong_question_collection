import { HuaweiIdentity } from './huawei-account.client';

export const HUAWEI_IDENTITY_PROVIDER = Symbol('HUAWEI_IDENTITY_PROVIDER');
export const ACCOUNT_STORE = Symbol('ACCOUNT_STORE');
export const DEVICE_SESSION_STORE = Symbol('DEVICE_SESSION_STORE');
export const IDENTITY_PROTECTOR = Symbol('IDENTITY_PROTECTOR');

export interface HuaweiIdentityProvider {
  exchangeAuthorizationCode(code: string): Promise<HuaweiIdentity>;
}

export interface StoredHuaweiIdentity {
  unionIdHash: string;
  encryptedUnionId: string;
  encryptedOpenId: string | null;
}

export interface UserRecord {
  id: string;
}

export interface DeviceRecord {
  id: string;
  name: string;
  sessionGeneration: string;
}

export interface AccountStore {
  findOrCreateHuaweiUser(identity: StoredHuaweiIdentity): Promise<UserRecord>;
}

export interface DeviceSessionStore {
  registerDevice(userId: string, deviceKey: string, deviceName: string): Promise<DeviceRecord>;
  replaceRefreshToken(
    userId: string,
    deviceId: string,
    sessionGeneration: string,
    refreshTokenHash: string
  ): Promise<boolean>;
  rotateRefreshToken(
    userId: string,
    deviceId: string,
    sessionGeneration: string,
    previousRefreshTokenHash: string,
    nextRefreshTokenHash: string
  ): Promise<boolean>;
  revokeDeviceWithRefreshToken(
    userId: string,
    deviceId: string,
    sessionGeneration: string,
    refreshTokenHash: string
  ): Promise<boolean>;
  isDeviceActive(
    userId: string,
    deviceId: string,
    sessionGeneration: string
  ): Promise<boolean>;
}
