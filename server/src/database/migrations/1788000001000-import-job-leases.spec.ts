import { QueryRunner } from 'typeorm';
import { ImportJobLeases1788000001000 } from './1788000001000-import-job-leases';

describe('ImportJobLeases1788000001000', () => {
  it('creates a job-keyed expiring lease table and rolls it back', async () => {
    const queries: string[] = [];
    const runner = { query: async (sql: string) => { queries.push(sql); } } as unknown as QueryRunner;
    const migration = new ImportJobLeases1788000001000();

    await migration.up(runner);
    expect(queries).toHaveLength(1);
    expect(queries[0]).toContain('CREATE TABLE `import_job_leases`');
    expect(queries[0]).toContain('PRIMARY KEY (`jobId`)');
    expect(queries[0]).toContain('`token` char(36) NOT NULL');
    expect(queries[0]).toContain('`expiresAt` datetime(3) NOT NULL');
    expect(queries[0]).toContain('FOREIGN KEY (`jobId`) REFERENCES `import_jobs` (`id`) ON DELETE CASCADE');

    queries.length = 0;
    await migration.down(runner);
    expect(queries).toEqual(['DROP TABLE IF EXISTS `import_job_leases`']);
  });
});
