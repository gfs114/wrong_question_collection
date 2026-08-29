import { validateEnvironment } from './environment';

const validEnvironment = (): Record<string, string> => ({
  NODE_ENV: 'test',
  PORT: '3000',
  DB_HOST: 'mysql',
  DB_PORT: '3306',
  DB_NAME: 'wrong_question',
  DB_USER: 'wqc_app',
  DB_PASSWORD: 'database-password-with-at-least-32-characters',
  DB_RUN_MIGRATIONS: 'false',
  JWT_ACCESS_SECRET: 'access-secret-with-at-least-32-characters',
  JWT_REFRESH_SECRET: 'refresh-secret-with-at-least-32-characters',
  DATA_ENCRYPTION_KEY: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  HUAWEI_CLIENT_ID: '123456789',
  HUAWEI_CLIENT_SECRET: 'huawei-client-secret',
  HUAWEI_TOKEN_URL: 'https://accounts.example.test/oauth2/v3/token',
  HUAWEI_PROFILE_URL: 'https://accounts.example.test/rest.php?nsp_svc=GOpen.User.getInfo',
  IMPORT_STORAGE_ROOT: process.platform === 'win32' ? 'C:\\import-storage' : '/var/lib/wqc-imports'
});

describe('validateEnvironment', () => {
  it('parses numeric ports and returns a typed configuration', () => {
    const result = validateEnvironment(validEnvironment());

    expect(result.PORT).toBe(3000);
    expect(result.DB_PORT).toBe(3306);
    expect(result.DB_NAME).toBe('wrong_question');
    expect(result.DB_RUN_MIGRATIONS).toBe(false);
    expect(result.IMPORT_MAX_PDF_BYTES).toBe(209715200);
    expect(result.IMPORT_PART_BYTES).toBe(4194304);
    expect(result.IMPORT_CONFIRM_MAX_BYTES).toBe(2 * 1024 * 1024);
    expect(result.IMPORT_ARTIFACT_TTL_HOURS).toBe(24);
    expect(result.IMPORT_MIN_FREE_BYTES).toBe(5368709120);
    expect(result.IMPORT_STORAGE_ROOT).toBe(validEnvironment().IMPORT_STORAGE_ROOT);
  });

  it('rejects a missing required value', () => {
    const environment = validEnvironment();
    delete environment.DB_PASSWORD;

    expect(() => validateEnvironment(environment)).toThrow('DB_PASSWORD is required');
  });

  it('rejects reused access and refresh secrets', () => {
    const environment = validEnvironment();
    environment.JWT_REFRESH_SECRET = environment.JWT_ACCESS_SECRET;

    expect(() => validateEnvironment(environment)).toThrow(
      'JWT_ACCESS_SECRET and JWT_REFRESH_SECRET must be different'
    );
  });

  it('requires a 32-byte hexadecimal data encryption key', () => {
    const environment = validEnvironment();
    environment.DATA_ENCRYPTION_KEY = 'short';

    expect(() => validateEnvironment(environment)).toThrow(
      'DATA_ENCRYPTION_KEY must be exactly 64 hexadecimal characters'
    );
  });

  it('requires HTTPS for Huawei credential endpoints', () => {
    const environment = validEnvironment();
    environment.HUAWEI_TOKEN_URL = 'http://accounts.example.test/token';

    expect(() => validateEnvironment(environment)).toThrow(
      'HUAWEI_TOKEN_URL must be a valid HTTPS URL'
    );
  });

  it('requires an absolute import storage root without exposing it in errors', () => {
    const environment = validEnvironment();
    environment.IMPORT_STORAGE_ROOT = '../private-imports';

    expect(() => validateEnvironment(environment)).toThrow(
      'IMPORT_STORAGE_ROOT must be an absolute path'
    );
  });

  it('validates bounded import storage limits', () => {
    const environment = validEnvironment();
    environment.IMPORT_MAX_PDF_BYTES = '209715201';

    expect(() => validateEnvironment(environment)).toThrow(
      'IMPORT_MAX_PDF_BYTES must be an integer between 1 and 209715200'
    );

    environment.IMPORT_MAX_PDF_BYTES = '209715200';
    environment.IMPORT_PART_BYTES = '1';
    expect(() => validateEnvironment(environment)).toThrow(
      'IMPORT_PART_BYTES must be an integer between 65536 and 4194304'
    );

    environment.IMPORT_PART_BYTES = '4194305';
    expect(() => validateEnvironment(environment)).toThrow(
      'IMPORT_PART_BYTES must be an integer between 65536 and 4194304'
    );

    environment.IMPORT_PART_BYTES = '4194304';
    environment.IMPORT_ARTIFACT_TTL_HOURS = '169';
    expect(() => validateEnvironment(environment)).toThrow(
      'IMPORT_ARTIFACT_TTL_HOURS must be an integer between 1 and 168'
    );

    environment.IMPORT_ARTIFACT_TTL_HOURS = '24';
    environment.IMPORT_MIN_FREE_BYTES = '0';
    expect(() => validateEnvironment(environment)).toThrow(
      'IMPORT_MIN_FREE_BYTES must be a positive integer'
    );

    environment.IMPORT_MIN_FREE_BYTES = '5368709120';
    environment.IMPORT_CONFIRM_MAX_BYTES = '65535';
    expect(() => validateEnvironment(environment)).toThrow(
      'IMPORT_CONFIRM_MAX_BYTES must be an integer between 65536 and 10485760'
    );
    environment.IMPORT_CONFIRM_MAX_BYTES = '10485761';
    expect(() => validateEnvironment(environment)).toThrow(
      'IMPORT_CONFIRM_MAX_BYTES must be an integer between 65536 and 10485760'
    );
  });
});
