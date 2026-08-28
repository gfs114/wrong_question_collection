import { Module } from '@nestjs/common';
import { APP_GUARD } from '@nestjs/core';
import { ConfigModule } from '@nestjs/config';
import { ThrottlerGuard, ThrottlerModule } from '@nestjs/throttler';
import { AuthModule } from './auth/auth.module';
import { validateEnvironment } from './config/environment';
import { DatabaseModule } from './database/database.module';
import { HealthModule } from './health/health.module';
import { ImportsModule } from './imports/import.module';
import { SyncModule } from './sync/sync.module';
import { createRateLimitOptions } from './security/rate-limit-options';

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      cache: true,
      validate: validateEnvironment
    }),
    ThrottlerModule.forRoot(createRateLimitOptions()),
    DatabaseModule,
    HealthModule,
    AuthModule,
    ImportsModule,
    SyncModule
  ],
  providers: [{ provide: APP_GUARD, useClass: ThrottlerGuard }]
})
export class AppModule {}
