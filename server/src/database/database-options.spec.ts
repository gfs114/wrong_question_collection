import { createDatabaseOptions, DatabaseEnvironmentConfig } from './database-options';
import { CloudImportSchema1788000000000 } from './migrations/1788000000000-cloud-import-schema';
import { ImportJobLeases1788000001000 } from './migrations/1788000001000-import-job-leases';
import { ImportConfirmations1788000002000 } from './migrations/1788000002000-import-confirmations';
import { InitialSchema1760000000000 } from './migrations/1760000000000-initial-schema';

describe('createDatabaseOptions', () => {
  it('connects to MySQL without schema synchronization or public assumptions', () => {
    const config: DatabaseEnvironmentConfig = {
      DB_HOST: 'mysql',
      DB_PORT: 3306,
      DB_NAME: 'wrong_question',
      DB_USER: 'wqc_app',
      DB_PASSWORD: 'database-password-with-at-least-32-characters',
      DB_RUN_MIGRATIONS: false
    };

    const options = createDatabaseOptions(config);

    expect(options).toMatchObject({
      type: 'mysql',
      host: 'mysql',
      port: 3306,
      database: 'wrong_question',
      username: 'wqc_app',
      synchronize: false,
      migrationsRun: false,
      charset: 'utf8mb4'
    });
    expect(options.entities).toHaveLength(17);
    expect(options.migrations).toEqual([
      InitialSchema1760000000000,
      CloudImportSchema1788000000000,
      ImportJobLeases1788000001000,
      ImportConfirmations1788000002000
    ]);
  });
});
