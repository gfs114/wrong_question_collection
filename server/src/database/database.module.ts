import { Module } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { TypeOrmModule } from '@nestjs/typeorm';
import { createDatabaseOptions, DatabaseEnvironmentConfig } from './database-options';
import { ALL_ENTITIES } from './entities';
import { TypeOrmAccountStore } from './typeorm-account.store';
import { TypeOrmDeviceSessionStore } from './typeorm-device-session.store';
import { TypeOrmSyncStore } from './typeorm-sync.store';

function databaseEnvironment(config: ConfigService): DatabaseEnvironmentConfig {
  return {
    DB_HOST: config.getOrThrow<string>('DB_HOST'),
    DB_PORT: config.getOrThrow<number>('DB_PORT'),
    DB_NAME: config.getOrThrow<string>('DB_NAME'),
    DB_USER: config.getOrThrow<string>('DB_USER'),
    DB_PASSWORD: config.getOrThrow<string>('DB_PASSWORD'),
    DB_RUN_MIGRATIONS: config.getOrThrow<boolean>('DB_RUN_MIGRATIONS')
  };
}

@Module({
  imports: [
    TypeOrmModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService) => createDatabaseOptions(databaseEnvironment(config))
    }),
    TypeOrmModule.forFeature(ALL_ENTITIES)
  ],
  providers: [TypeOrmAccountStore, TypeOrmDeviceSessionStore, TypeOrmSyncStore],
  exports: [TypeOrmModule, TypeOrmAccountStore, TypeOrmDeviceSessionStore, TypeOrmSyncStore]
})
export class DatabaseModule {}
