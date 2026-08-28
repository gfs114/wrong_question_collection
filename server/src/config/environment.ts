import { isAbsolute } from 'node:path';
import { MAX_UPLOAD_PART_BYTES, MIN_UPLOAD_PART_BYTES } from '../imports/import.contracts';

export type NodeEnvironment = 'development' | 'test' | 'production';

export interface EnvironmentConfig {
  NODE_ENV: NodeEnvironment;
  PORT: number;
  DB_HOST: string;
  DB_PORT: number;
  DB_NAME: string;
  DB_USER: string;
  DB_PASSWORD: string;
  DB_RUN_MIGRATIONS: boolean;
  JWT_ACCESS_SECRET: string;
  JWT_REFRESH_SECRET: string;
  DATA_ENCRYPTION_KEY: string;
  HUAWEI_CLIENT_ID: string;
  HUAWEI_CLIENT_SECRET: string;
  HUAWEI_TOKEN_URL: string;
  HUAWEI_PROFILE_URL: string;
  IMPORT_STORAGE_ROOT: string;
  IMPORT_MAX_PDF_BYTES: number;
  IMPORT_PART_BYTES: number;
  IMPORT_ARTIFACT_TTL_HOURS: number;
  IMPORT_MIN_FREE_BYTES: number;
}

function requiredString(environment: Record<string, unknown>, key: string): string {
  const value = environment[key];
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new Error(`${key} is required`);
  }
  return value.trim();
}

function parsePort(environment: Record<string, unknown>, key: string): number {
  const value = requiredString(environment, key);
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 65535) {
    throw new Error(`${key} must be an integer between 1 and 65535`);
  }
  return parsed;
}

function parseNodeEnvironment(environment: Record<string, unknown>): NodeEnvironment {
  const value = requiredString(environment, 'NODE_ENV');
  if (value !== 'development' && value !== 'test' && value !== 'production') {
    throw new Error('NODE_ENV must be development, test, or production');
  }
  return value;
}

function parseBoolean(environment: Record<string, unknown>, key: string): boolean {
  const value = requiredString(environment, key).toLowerCase();
  if (value === 'true') {
    return true;
  }
  if (value === 'false') {
    return false;
  }
  throw new Error(`${key} must be true or false`);
}

function requireSecret(environment: Record<string, unknown>, key: string): string {
  const value = requiredString(environment, key);
  if (value.length < 32) {
    throw new Error(`${key} must contain at least 32 characters`);
  }
  return value;
}

function requireHttpsUrl(environment: Record<string, unknown>, key: string): string {
  const value = requiredString(environment, key);
  try {
    const url = new URL(value);
    if (url.protocol === 'https:' && url.username === '' && url.password === '') {
      return value;
    }
  } catch {
    // Use one stable configuration error below.
  }
  throw new Error(`${key} must be a valid HTTPS URL`);
}

function parseIntegerWithDefault(
  environment: Record<string, unknown>,
  key: string,
  defaultValue: number,
  min: number,
  max: number,
  error: string
): number {
  const value = environment[key];
  if (value === undefined) {
    return defaultValue;
  }
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new Error(error);
  }
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < min || parsed > max) {
    throw new Error(error);
  }
  return parsed;
}

function importStorageRoot(environment: Record<string, unknown>): string {
  const root = requiredString(environment, 'IMPORT_STORAGE_ROOT');
  if (!isAbsolute(root)) {
    throw new Error('IMPORT_STORAGE_ROOT must be an absolute path');
  }
  return root;
}

export function validateEnvironment(environment: Record<string, unknown>): EnvironmentConfig {
  const accessSecret = requireSecret(environment, 'JWT_ACCESS_SECRET');
  const refreshSecret = requireSecret(environment, 'JWT_REFRESH_SECRET');
  if (accessSecret === refreshSecret) {
    throw new Error('JWT_ACCESS_SECRET and JWT_REFRESH_SECRET must be different');
  }

  const encryptionKey = requiredString(environment, 'DATA_ENCRYPTION_KEY').toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(encryptionKey)) {
    throw new Error('DATA_ENCRYPTION_KEY must be exactly 64 hexadecimal characters');
  }

  const maxPdfBytes = parseIntegerWithDefault(
    environment,
    'IMPORT_MAX_PDF_BYTES',
    209715200,
    1,
    209715200,
    'IMPORT_MAX_PDF_BYTES must be an integer between 1 and 209715200'
  );
  const partBytes = parseIntegerWithDefault(
    environment,
    'IMPORT_PART_BYTES',
    4194304,
    MIN_UPLOAD_PART_BYTES,
    MAX_UPLOAD_PART_BYTES,
    'IMPORT_PART_BYTES must be an integer between 65536 and 4194304'
  );
  if (partBytes > maxPdfBytes) {
    throw new Error('IMPORT_PART_BYTES must not exceed IMPORT_MAX_PDF_BYTES');
  }
  const artifactTtlHours = parseIntegerWithDefault(
    environment,
    'IMPORT_ARTIFACT_TTL_HOURS',
    24,
    1,
    168,
    'IMPORT_ARTIFACT_TTL_HOURS must be an integer between 1 and 168'
  );
  const minFreeBytes = parseIntegerWithDefault(
    environment,
    'IMPORT_MIN_FREE_BYTES',
    5368709120,
    1,
    Number.MAX_SAFE_INTEGER,
    'IMPORT_MIN_FREE_BYTES must be a positive integer'
  );

  return {
    NODE_ENV: parseNodeEnvironment(environment),
    PORT: parsePort(environment, 'PORT'),
    DB_HOST: requiredString(environment, 'DB_HOST'),
    DB_PORT: parsePort(environment, 'DB_PORT'),
    DB_NAME: requiredString(environment, 'DB_NAME'),
    DB_USER: requiredString(environment, 'DB_USER'),
    DB_PASSWORD: requireSecret(environment, 'DB_PASSWORD'),
    DB_RUN_MIGRATIONS: parseBoolean(environment, 'DB_RUN_MIGRATIONS'),
    JWT_ACCESS_SECRET: accessSecret,
    JWT_REFRESH_SECRET: refreshSecret,
    DATA_ENCRYPTION_KEY: encryptionKey,
    HUAWEI_CLIENT_ID: requiredString(environment, 'HUAWEI_CLIENT_ID'),
    HUAWEI_CLIENT_SECRET: requiredString(environment, 'HUAWEI_CLIENT_SECRET'),
    HUAWEI_TOKEN_URL: requireHttpsUrl(environment, 'HUAWEI_TOKEN_URL'),
    HUAWEI_PROFILE_URL: requireHttpsUrl(environment, 'HUAWEI_PROFILE_URL'),
    IMPORT_STORAGE_ROOT: importStorageRoot(environment),
    IMPORT_MAX_PDF_BYTES: maxPdfBytes,
    IMPORT_PART_BYTES: partBytes,
    IMPORT_ARTIFACT_TTL_HOURS: artifactTtlHours,
    IMPORT_MIN_FREE_BYTES: minFreeBytes
  };
}
