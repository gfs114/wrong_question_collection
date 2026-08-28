import { TypeOrmModuleOptions } from '@nestjs/typeorm';
import { DataSourceOptions } from 'typeorm';
import { ALL_ENTITIES } from './entities';
import { InitialSchema1760000000000 } from './migrations/1760000000000-initial-schema';
import { CloudImportSchema1788000000000 } from './migrations/1788000000000-cloud-import-schema';
import { ImportJobLeases1788000001000 } from './migrations/1788000001000-import-job-leases';
import { ImportConfirmations1788000002000 } from './migrations/1788000002000-import-confirmations';

export interface DatabaseEnvironmentConfig {
  DB_HOST: string;
  DB_PORT: number;
  DB_NAME: string;
  DB_USER: string;
  DB_PASSWORD: string;
  DB_RUN_MIGRATIONS: boolean;
}

export function createDataSourceOptions(config: DatabaseEnvironmentConfig): DataSourceOptions {
  return {
    type: 'mysql',
    host: config.DB_HOST,
    port: config.DB_PORT,
    database: config.DB_NAME,
    username: config.DB_USER,
    password: config.DB_PASSWORD,
    charset: 'utf8mb4',
    timezone: 'Z',
    entities: ALL_ENTITIES,
    migrations: [
      InitialSchema1760000000000,
      CloudImportSchema1788000000000,
      ImportJobLeases1788000001000,
      ImportConfirmations1788000002000
    ],
    migrationsRun: config.DB_RUN_MIGRATIONS,
    synchronize: false,
    logging: false
  };
}

export function createDatabaseOptions(config: DatabaseEnvironmentConfig): TypeOrmModuleOptions {
  return {
    ...createDataSourceOptions(config),
    retryAttempts: 10,
    retryDelay: 3000
  };
}
