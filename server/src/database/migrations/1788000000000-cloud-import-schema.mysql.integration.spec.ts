import { createConnection, type Connection } from 'mysql2/promise';
import { QueryRunner } from 'typeorm';
import { InitialSchema1760000000000 } from './1760000000000-initial-schema';
import { CloudImportSchema1788000000000 } from './1788000000000-cloud-import-schema';
import { ImportJobLeases1788000001000 } from './1788000001000-import-job-leases';

interface MySqlIntegrationConfig {
  host: string;
  port: number;
  user: string;
  password: string;
  databasePrefix: string;
}

const config = readIntegrationConfig();
const describeMySql = config ? describe : describe.skip;

describe('MySQL integration configuration', () => {
  it('fails clearly when the dedicated schema test requires missing credentials', () => {
    expect(() => readIntegrationConfig({ MYSQL_INTEGRATION_REQUIRED: 'true' }, true)).toThrow(
      'MYSQL_INTEGRATION_REQUIRED needs MYSQL_INTEGRATION_HOST, MYSQL_INTEGRATION_USER, MYSQL_INTEGRATION_PASSWORD, and MYSQL_INTEGRATION_DATABASE.'
    );
  });
});

describeMySql('CloudImportSchema1788000000000 MySQL 8.4 integration', () => {
  let admin: Connection | undefined;
  let connection: Connection | undefined;
  let databaseName = '';

  beforeAll(async () => {
    const mysqlConfig = config!;
    databaseName = `${mysqlConfig.databasePrefix.slice(0, 36)}_${process.pid}_${Date.now()}`;
    admin = await createConnection(mysqlConfig);
    await admin.query(`CREATE DATABASE \`${databaseName}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci`);
    connection = await createConnection({ ...mysqlConfig, database: databaseName });

    const queryRunner = {
      query: async (statement: string) => connection!.query(statement)
    } as unknown as QueryRunner;
    await new InitialSchema1760000000000().up(queryRunner);
    await new CloudImportSchema1788000000000().up(queryRunner);
    await new ImportJobLeases1788000001000().up(queryRunner);
  }, 30000);

  afterAll(async () => {
    await connection?.end();
    if (admin && databaseName) {
      await admin.query(`DROP DATABASE IF EXISTS \`${databaseName}\``);
    }
    await admin?.end();
  }, 30000);

  it('enforces cloud-import constraints and foreign-key ownership in an isolated database', async () => {
    const db = connection!;
    const importTables = await tableNames(db);
    expect(importTables).toEqual(expect.arrayContaining([
      'import_jobs',
      'import_upload_parts',
      'import_draft_questions',
      'import_artifacts',
      'import_job_leases'
    ]));

    const constraints = await constraintNames(db);
    expect(constraints).toEqual(expect.arrayContaining([
      'fk_import_job_device_owner',
      'fk_import_job_lease_job',
      'fk_import_artifact_draft_owner',
      'chk_import_job_status',
      'chk_import_draft_confidence',
      'chk_import_artifact_type'
    ]));

    const userA = '00000000-0000-0000-0000-000000000001';
    const userB = '00000000-0000-0000-0000-000000000002';
    const deviceA = '00000000-0000-0000-0000-000000000011';
    const jobA = '00000000-0000-0000-0000-000000000021';
    const jobB = '00000000-0000-0000-0000-000000000022';
    const draftA = '00000000-0000-0000-0000-000000000031';
    const artifactA = '00000000-0000-0000-0000-000000000041';

    await db.query('INSERT INTO users (id, status) VALUES (?, ?), (?, ?)', [userA, 'active', userB, 'active']);
    await db.query(
      'INSERT INTO devices (id, userId, deviceKey, name, sessionGeneration, lastSeenAt) VALUES (?, ?, ?, ?, ?, NOW(3))',
      [deviceA, userA, 'device-a', 'Device A', '00000000-0000-0000-0000-000000000012']
    );
    await insertJob(db, jobA, userA, deviceA);
    await insertJob(db, jobB, userA, deviceA);
    await db.query(
      'INSERT INTO import_upload_parts (id, jobId, partNumber, size, sha256, storageKey) VALUES (?, ?, ?, ?, ?, ?)',
      ['00000000-0000-0000-0000-000000000051', jobA, 0, 1, 'a'.repeat(64), 'parts/a']
    );
    await db.query(
      'INSERT INTO import_draft_questions (id, jobId, position, type, question, pageStart, pageEnd, confidence, reviewRequired) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [draftA, jobA, 0, 'single_choice', 'Question', 1, 1, 0.875, 1]
    );
    await db.query(
      'INSERT INTO import_artifacts (id, jobId, draftQuestionId, type, storageKey, sha256, size, expiresAt) VALUES (?, ?, ?, ?, ?, ?, ?, DATE_ADD(NOW(3), INTERVAL 1 DAY))',
      [artifactA, jobA, draftA, 'question_image', 'artifacts/a', 'b'.repeat(64), 1]
    );
    await db.query(
      'INSERT INTO import_job_leases (jobId, token, expiresAt) VALUES (?, ?, DATE_ADD(NOW(3), INTERVAL 1 HOUR))',
      [jobA, '00000000-0000-4000-8000-000000000061']
    );

    await expect(insertJob(db, '00000000-0000-0000-0000-000000000023', userB, deviceA)).rejects.toBeDefined();
    await expect(
      db.query(
        'INSERT INTO import_jobs (id, userId, deviceId, bankName, subject, pageStart, pageEnd, status, sourceSha256, sourceSize, partCount, expiresAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, DATE_ADD(NOW(3), INTERVAL 1 DAY))',
        ['00000000-0000-0000-0000-000000000024', userA, deviceA, 'Bank', 'Math', 1, 1, 'invalid', 'c'.repeat(64), 1, 0]
      )
    ).rejects.toBeDefined();
    await expect(
      db.query(
        'INSERT INTO import_artifacts (id, jobId, draftQuestionId, type, storageKey, sha256, size, expiresAt) VALUES (?, ?, ?, ?, ?, ?, ?, DATE_ADD(NOW(3), INTERVAL 1 DAY))',
        ['00000000-0000-0000-0000-000000000042', jobB, draftA, 'question_image', 'artifacts/b', 'd'.repeat(64), 1]
      )
    ).rejects.toBeDefined();

    await db.query('DELETE FROM import_jobs WHERE id = ?', [jobA]);
    expect(await rowCount(db, 'import_upload_parts')).toBe(0);
    expect(await rowCount(db, 'import_draft_questions')).toBe(0);
    expect(await rowCount(db, 'import_artifacts')).toBe(0);
    expect(await rowCount(db, 'import_job_leases')).toBe(0);

    const queryRunner = { query: async (statement: string) => db.query(statement) } as unknown as QueryRunner;
    await new ImportJobLeases1788000001000().down(queryRunner);
    await new CloudImportSchema1788000000000().down(queryRunner);
    expect(await tableNames(db)).not.toEqual(expect.arrayContaining([
      'import_jobs',
      'import_upload_parts',
      'import_draft_questions',
      'import_artifacts'
    ]));
    await new InitialSchema1760000000000().down(queryRunner);
  }, 30000);
});

function readIntegrationConfig(
  environment: NodeJS.ProcessEnv = process.env,
  required = environment.MYSQL_INTEGRATION_REQUIRED === 'true'
): MySqlIntegrationConfig | undefined {
  const { MYSQL_INTEGRATION_HOST, MYSQL_INTEGRATION_PORT, MYSQL_INTEGRATION_USER, MYSQL_INTEGRATION_PASSWORD, MYSQL_INTEGRATION_DATABASE } = environment;

  if (!MYSQL_INTEGRATION_HOST || !MYSQL_INTEGRATION_USER || !MYSQL_INTEGRATION_PASSWORD || !MYSQL_INTEGRATION_DATABASE) {
    if (required) {
      throw new Error(
        'MYSQL_INTEGRATION_REQUIRED needs MYSQL_INTEGRATION_HOST, MYSQL_INTEGRATION_USER, MYSQL_INTEGRATION_PASSWORD, and MYSQL_INTEGRATION_DATABASE.'
      );
    }
    return undefined;
  }
  if (!/^[A-Za-z0-9_]+$/.test(MYSQL_INTEGRATION_DATABASE)) {
    throw new Error('MYSQL_INTEGRATION_DATABASE must be an alphanumeric database-name prefix.');
  }

  return {
    host: MYSQL_INTEGRATION_HOST,
    port: Number(MYSQL_INTEGRATION_PORT ?? 3306),
    user: MYSQL_INTEGRATION_USER,
    password: MYSQL_INTEGRATION_PASSWORD,
    databasePrefix: MYSQL_INTEGRATION_DATABASE
  };
}

async function tableNames(connection: Connection): Promise<string[]> {
  const [rows] = await connection.query(
    'SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE()'
  );
  return (rows as Array<{ TABLE_NAME: string }>).map((row) => row.TABLE_NAME);
}

async function constraintNames(connection: Connection): Promise<string[]> {
  const [rows] = await connection.query(
    'SELECT CONSTRAINT_NAME FROM information_schema.TABLE_CONSTRAINTS WHERE TABLE_SCHEMA = DATABASE()'
  );
  return (rows as Array<{ CONSTRAINT_NAME: string }>).map((row) => row.CONSTRAINT_NAME);
}

async function rowCount(connection: Connection, table: string): Promise<number> {
  const [rows] = await connection.query(`SELECT COUNT(*) AS count FROM \`${table}\``);
  return Number((rows as Array<{ count: number | string }>)[0].count);
}

async function insertJob(connection: Connection, id: string, userId: string, deviceId: string): Promise<void> {
  await connection.query(
    'INSERT INTO import_jobs (id, userId, deviceId, bankName, subject, pageStart, pageEnd, sourceSha256, sourceSize, partCount, expiresAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, DATE_ADD(NOW(3), INTERVAL 1 DAY))',
    [id, userId, deviceId, 'Bank', 'Math', 1, 2, 'a'.repeat(64), 1, 1]
  );
}
