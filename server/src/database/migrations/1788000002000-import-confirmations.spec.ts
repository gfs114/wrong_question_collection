import { QueryRunner } from 'typeorm';
import { ImportConfirmations1788000002000 } from './1788000002000-import-confirmations';

describe('ImportConfirmations1788000002000', () => {
  it('persists idempotent mappings, ACK state and cleanup checkpoints with reversible FKs', async () => {
    const queries: string[] = [];
    const runner = { query: async (sql: string) => { queries.push(sql); } } as unknown as QueryRunner;
    const migration = new ImportConfirmations1788000002000();

    await migration.up(runner);
    expect(queries.join('\n')).toContain('CREATE TABLE `import_confirmations`');
    expect(queries.join('\n')).toContain('`requestSha256` char(64) NOT NULL');
    expect(queries.join('\n')).toContain('`acknowledgedAt` datetime(3) NULL');
    expect(queries.join('\n')).toContain('CREATE TABLE `import_confirmed_questions`');
    expect(queries.join('\n')).toContain('UNIQUE KEY `uq_import_confirmed_draft` (`jobId`, `draftQuestionId`)');
    expect(queries.join('\n')).toContain('CREATE TABLE `import_cleanup_checkpoints`');
    expect(queries.join('\n')).toContain('`retiredAt` datetime(3) NULL');

    queries.length = 0;
    await migration.down(runner);
    expect(queries).toEqual([
      'DROP TABLE IF EXISTS `import_cleanup_checkpoints`',
      'DROP TABLE IF EXISTS `import_confirmed_questions`',
      'DROP TABLE IF EXISTS `import_confirmations`'
    ]);
  });
});
