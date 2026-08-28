import { MigrationInterface, QueryRunner } from 'typeorm';

export class ImportJobLeases1788000001000 implements MigrationInterface {
  name = 'ImportJobLeases1788000001000';

  async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`CREATE TABLE \`import_job_leases\` (
      \`jobId\` char(36) NOT NULL,
      \`token\` char(36) NOT NULL,
      \`expiresAt\` datetime(3) NOT NULL,
      \`createdAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
      \`updatedAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
      KEY \`idx_import_job_lease_expiry\` (\`expiresAt\`),
      CONSTRAINT \`fk_import_job_lease_job\` FOREIGN KEY (\`jobId\`) REFERENCES \`import_jobs\` (\`id\`) ON DELETE CASCADE,
      PRIMARY KEY (\`jobId\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`);
  }

  async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query('DROP TABLE IF EXISTS `import_job_leases`');
  }
}
