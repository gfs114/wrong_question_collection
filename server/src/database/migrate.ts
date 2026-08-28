import 'reflect-metadata';
import { DataSource } from 'typeorm';
import { createDataSourceOptions, DatabaseEnvironmentConfig } from './database-options';

function requiredEnvironment(key: string): string {
  const value = process.env[key];
  if (value === undefined || value.trim().length === 0) {
    throw new Error(`${key} is required`);
  }
  return value.trim();
}

function migrationEnvironment(): DatabaseEnvironmentConfig {
  const port = Number(requiredEnvironment('DB_PORT'));
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('DB_PORT must be an integer between 1 and 65535');
  }
  const password = requiredEnvironment('DB_PASSWORD');
  if (password.length < 32) {
    throw new Error('DB_PASSWORD must contain at least 32 characters');
  }
  return {
    DB_HOST: requiredEnvironment('DB_HOST'),
    DB_PORT: port,
    DB_NAME: requiredEnvironment('DB_NAME'),
    DB_USER: requiredEnvironment('DB_USER'),
    DB_PASSWORD: password,
    DB_RUN_MIGRATIONS: false
  };
}

export async function runMigrations(dataSource: DataSource): Promise<void> {
  await dataSource.initialize();
  try {
    await dataSource.runMigrations({ transaction: 'all' });
  } finally {
    await dataSource.destroy();
  }
}

async function main(): Promise<void> {
  const config = migrationEnvironment();
  const dataSource = new DataSource(createDataSourceOptions(config));
  await runMigrations(dataSource);
}

if (require.main === module) {
  void main().catch((error: unknown) => {
    const message = error instanceof Error ? error.message : 'Unknown migration error';
    process.stderr.write(`Database migration failed: ${message}\n`);
    process.exitCode = 1;
  });
}
