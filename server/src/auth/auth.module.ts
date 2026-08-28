import { Module } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtModule } from '@nestjs/jwt';
import {
  ACCOUNT_STORE,
  DEVICE_SESSION_STORE,
  HUAWEI_IDENTITY_PROVIDER,
  IDENTITY_PROTECTOR
} from './auth.contracts';
import { AccessTokenGuard } from './access-token.guard';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import {
  HUAWEI_CLIENT_ID,
  HUAWEI_CLIENT_SECRET,
  HUAWEI_PROFILE_URL,
  HUAWEI_TOKEN_URL,
  HuaweiAccountClient
} from './huawei-account.client';
import {
  JWT_ACCESS_SECRET,
  JWT_REFRESH_SECRET,
  TokenService
} from './token.service';
import { DatabaseModule } from '../database/database.module';
import { TypeOrmAccountStore } from '../database/typeorm-account.store';
import { TypeOrmDeviceSessionStore } from '../database/typeorm-device-session.store';
import {
  FetchFormHttpClient,
  FORM_HTTP_CLIENT
} from '../http/form-http-client';
import { IdentityProtector } from '../security/identity-protector';

@Module({
  imports: [DatabaseModule, JwtModule.register({})],
  controllers: [AuthController],
  providers: [
    AuthService,
    TokenService,
    AccessTokenGuard,
    HuaweiAccountClient,
    { provide: FORM_HTTP_CLIENT, useClass: FetchFormHttpClient },
    { provide: HUAWEI_IDENTITY_PROVIDER, useExisting: HuaweiAccountClient },
    { provide: ACCOUNT_STORE, useExisting: TypeOrmAccountStore },
    { provide: DEVICE_SESSION_STORE, useExisting: TypeOrmDeviceSessionStore },
    {
      provide: IDENTITY_PROTECTOR,
      inject: [ConfigService],
      useFactory: (config: ConfigService) =>
        new IdentityProtector(config.getOrThrow<string>('DATA_ENCRYPTION_KEY'))
    },
    {
      provide: JWT_ACCESS_SECRET,
      inject: [ConfigService],
      useFactory: (config: ConfigService) => config.getOrThrow<string>('JWT_ACCESS_SECRET')
    },
    {
      provide: JWT_REFRESH_SECRET,
      inject: [ConfigService],
      useFactory: (config: ConfigService) => config.getOrThrow<string>('JWT_REFRESH_SECRET')
    },
    {
      provide: HUAWEI_CLIENT_ID,
      inject: [ConfigService],
      useFactory: (config: ConfigService) => config.getOrThrow<string>('HUAWEI_CLIENT_ID')
    },
    {
      provide: HUAWEI_CLIENT_SECRET,
      inject: [ConfigService],
      useFactory: (config: ConfigService) => config.getOrThrow<string>('HUAWEI_CLIENT_SECRET')
    },
    {
      provide: HUAWEI_TOKEN_URL,
      inject: [ConfigService],
      useFactory: (config: ConfigService) => config.getOrThrow<string>('HUAWEI_TOKEN_URL')
    },
    {
      provide: HUAWEI_PROFILE_URL,
      inject: [ConfigService],
      useFactory: (config: ConfigService) => config.getOrThrow<string>('HUAWEI_PROFILE_URL')
    }
  ],
  exports: [TokenService, AccessTokenGuard, DEVICE_SESSION_STORE]
})
export class AuthModule {}
