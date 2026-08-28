import { MigrationInterface, QueryRunner } from 'typeorm';

export class ImportConfirmations1788000002000 implements MigrationInterface {
  name = 'ImportConfirmations1788000002000';

  async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`CREATE TABLE \`import_confirmations\` (
      \`id\` char(36) NOT NULL,
      \`jobId\` char(36) NOT NULL,
      \`userId\` char(36) NOT NULL,
      \`deviceId\` char(36) NOT NULL,
      \`requestSha256\` char(64) NOT NULL,
      \`bankId\` char(36) NOT NULL,
      \`acknowledgedAt\` datetime(3) NULL,
      \`expiresAt\` datetime(3) NOT NULL,
      \`createdAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
      \`updatedAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
      UNIQUE KEY \`uq_import_confirmation_job\` (\`jobId\`),
      KEY \`idx_import_confirmation_expiry\` (\`expiresAt\`),
      CONSTRAINT \`fk_import_confirmation_job\` FOREIGN KEY (\`jobId\`) REFERENCES \`import_jobs\` (\`id\`) ON DELETE CASCADE,
      CONSTRAINT \`fk_import_confirmation_user\` FOREIGN KEY (\`userId\`) REFERENCES \`users\` (\`id\`) ON DELETE CASCADE,
      CONSTRAINT \`fk_import_confirmation_device\` FOREIGN KEY (\`userId\`, \`deviceId\`) REFERENCES \`devices\` (\`userId\`, \`id\`) ON DELETE CASCADE,
      PRIMARY KEY (\`id\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`);

    await queryRunner.query(`CREATE TABLE \`import_confirmed_questions\` (
      \`id\` char(36) NOT NULL,
      \`jobId\` char(36) NOT NULL,
      \`draftQuestionId\` char(36) NOT NULL,
      \`questionId\` char(36) NOT NULL,
      \`position\` int unsigned NOT NULL,
      \`createdAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
      \`updatedAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
      UNIQUE KEY \`uq_import_confirmed_draft\` (\`jobId\`, \`draftQuestionId\`),
      UNIQUE KEY \`uq_import_confirmed_position\` (\`jobId\`, \`position\`),
      CONSTRAINT \`fk_import_confirmed_job\` FOREIGN KEY (\`jobId\`) REFERENCES \`import_confirmations\` (\`jobId\`) ON DELETE CASCADE,
      CONSTRAINT \`fk_import_confirmed_draft\` FOREIGN KEY (\`jobId\`, \`draftQuestionId\`) REFERENCES \`import_draft_questions\` (\`jobId\`, \`id\`) ON DELETE CASCADE,
      PRIMARY KEY (\`id\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`);

    await queryRunner.query(`CREATE TABLE \`import_cleanup_checkpoints\` (
      \`jobId\` char(36) NOT NULL,
      \`missingSince\` datetime(3) NOT NULL,
      \`retiredAt\` datetime(3) NULL,
      \`createdAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
      \`updatedAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
      CONSTRAINT \`fk_import_cleanup_checkpoint_job\` FOREIGN KEY (\`jobId\`) REFERENCES \`import_jobs\` (\`id\`) ON DELETE CASCADE,
      PRIMARY KEY (\`jobId\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`);
  }

  async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query('DROP TABLE IF EXISTS `import_cleanup_checkpoints`');
    await queryRunner.query('DROP TABLE IF EXISTS `import_confirmed_questions`');
    await queryRunner.query('DROP TABLE IF EXISTS `import_confirmations`');
  }
}
