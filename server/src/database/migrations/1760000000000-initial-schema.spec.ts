import { QueryRunner } from 'typeorm';
import { InitialSchema1760000000000 } from './1760000000000-initial-schema';

describe('InitialSchema1760000000000', () => {
  it('creates every required table without exposing a database listener', async () => {
    const statements: string[] = [];
    const queryRunner = {
      query: async (statement: string) => {
        statements.push(statement);
      }
    } as unknown as QueryRunner;

    await new InitialSchema1760000000000().up(queryRunner);

    for (const table of [
      'users',
      'huawei_identities',
      'devices',
      'sessions',
      'question_banks',
      'questions',
      'wrong_questions',
      'review_records',
      'sync_operations'
    ]) {
      expect(statements.some((statement) => statement.includes(`CREATE TABLE \`${table}\``))).toBe(
        true
      );
    }
    expect(statements.join('\n')).toContain('AUTO_INCREMENT');
    expect(statements.join('\n')).toContain('`sessionGeneration` char(36) NOT NULL');
    expect(statements.join('\n')).not.toContain('GRANT ');
  });

  it('drops tables in dependency-safe reverse order', async () => {
    const statements: string[] = [];
    const queryRunner = {
      query: async (statement: string) => {
        statements.push(statement);
      }
    } as unknown as QueryRunner;

    await new InitialSchema1760000000000().down(queryRunner);

    expect(statements[0]).toContain('sync_operations');
    expect(statements.at(-1)).toContain('users');
  });
});
