import { MigrationInterface, QueryRunner } from 'typeorm';

export class CloudImportSchema1788000000000 implements MigrationInterface {
  name = 'CloudImportSchema1788000000000';

  async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      'ALTER TABLE `devices` ADD UNIQUE KEY `uq_device_user_id` (`userId`, `id`)'
    );

    await queryRunner.query(`CREATE TABLE \`import_jobs\` (
      \`id\` char(36) NOT NULL,
      \`userId\` char(36) NOT NULL,
      \`deviceId\` char(36) NOT NULL,
      \`bankName\` varchar(255) NOT NULL,
      \`subject\` varchar(64) NOT NULL,
      \`pageStart\` int unsigned NOT NULL,
      \`pageEnd\` int unsigned NOT NULL,
      \`status\` varchar(24) NOT NULL DEFAULT 'uploading',
      \`progressCurrent\` int unsigned NOT NULL DEFAULT 0,
      \`progressTotal\` int unsigned NOT NULL DEFAULT 0,
      \`sourceSha256\` char(64) NOT NULL,
      \`sourceSize\` bigint unsigned NOT NULL,
      \`partCount\` int unsigned NOT NULL,
      \`retryCount\` int unsigned NOT NULL DEFAULT 0,
      \`errorCode\` varchar(64) NULL,
      \`claimedAt\` datetime(3) NULL,
      \`expiresAt\` datetime(3) NOT NULL,
      \`createdAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
      \`updatedAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
      KEY \`idx_import_job_device\` (\`deviceId\`),
      KEY \`idx_import_job_user_device\` (\`userId\`, \`deviceId\`),
      KEY \`idx_import_job_status_created\` (\`status\`, \`createdAt\`),
      KEY \`idx_import_job_expiry\` (\`expiresAt\`),
      CONSTRAINT \`chk_import_job_status\` CHECK (\`status\` IN ('uploading', 'queued', 'processing', 'review', 'confirmed', 'failed', 'cancelled', 'expired')),
      CONSTRAINT \`chk_import_job_page_range\` CHECK (\`pageStart\` >= 1 AND \`pageEnd\` >= \`pageStart\` AND \`pageEnd\` <= \`pageStart\` + 19),
      CONSTRAINT \`chk_import_job_source_size\` CHECK (\`sourceSize\` BETWEEN 1 AND 209715200),
      CONSTRAINT \`chk_import_job_progress\` CHECK (\`progressCurrent\` <= \`progressTotal\`),
      CONSTRAINT \`chk_import_job_retry_count\` CHECK (\`retryCount\` BETWEEN 0 AND 2),
      CONSTRAINT \`chk_import_job_part_count\` CHECK (\`partCount\` >= 0),
      CONSTRAINT \`fk_import_job_user\` FOREIGN KEY (\`userId\`) REFERENCES \`users\` (\`id\`) ON DELETE CASCADE,
      CONSTRAINT \`fk_import_job_device_owner\` FOREIGN KEY (\`userId\`, \`deviceId\`) REFERENCES \`devices\` (\`userId\`, \`id\`) ON DELETE CASCADE,
      PRIMARY KEY (\`id\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`);

    await queryRunner.query(`CREATE TABLE \`import_upload_parts\` (
      \`id\` char(36) NOT NULL,
      \`jobId\` char(36) NOT NULL,
      \`partNumber\` int unsigned NOT NULL,
      \`size\` bigint unsigned NOT NULL,
      \`sha256\` char(64) NOT NULL,
      \`storageKey\` varchar(512) NOT NULL,
      \`createdAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
      \`updatedAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
      UNIQUE KEY \`uq_import_part_job_number\` (\`jobId\`, \`partNumber\`),
      CONSTRAINT \`chk_import_part_number\` CHECK (\`partNumber\` >= 0),
      CONSTRAINT \`fk_import_part_job\` FOREIGN KEY (\`jobId\`) REFERENCES \`import_jobs\` (\`id\`) ON DELETE CASCADE,
      PRIMARY KEY (\`id\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`);

    await queryRunner.query(`CREATE TABLE \`import_draft_questions\` (
      \`id\` char(36) NOT NULL,
      \`jobId\` char(36) NOT NULL,
      \`position\` int unsigned NOT NULL,
      \`type\` varchar(32) NOT NULL,
      \`question\` longtext NOT NULL,
      \`options\` json NULL,
      \`answer\` longtext NULL,
      \`analysis\` longtext NULL,
      \`pageStart\` int unsigned NOT NULL,
      \`pageEnd\` int unsigned NOT NULL,
      \`confidence\` decimal(5,4) NOT NULL DEFAULT 0,
      \`reviewRequired\` tinyint NOT NULL DEFAULT 1,
      \`createdAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
      \`updatedAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
      UNIQUE KEY \`uq_import_draft_job_position\` (\`jobId\`, \`position\`),
      UNIQUE KEY \`uq_import_draft_job_id\` (\`jobId\`, \`id\`),
      CONSTRAINT \`chk_import_draft_position\` CHECK (\`position\` >= 0),
      CONSTRAINT \`chk_import_draft_page_range\` CHECK (\`pageStart\` >= 1 AND \`pageEnd\` >= \`pageStart\` AND \`pageEnd\` <= \`pageStart\` + 19),
      CONSTRAINT \`chk_import_draft_confidence\` CHECK (\`confidence\` BETWEEN 0 AND 1),
      CONSTRAINT \`chk_import_draft_review_required\` CHECK (\`reviewRequired\` IN (0, 1)),
      CONSTRAINT \`fk_import_draft_job\` FOREIGN KEY (\`jobId\`) REFERENCES \`import_jobs\` (\`id\`) ON DELETE CASCADE,
      PRIMARY KEY (\`id\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`);

    await queryRunner.query(`CREATE TABLE \`import_artifacts\` (
      \`id\` char(36) NOT NULL,
      \`jobId\` char(36) NOT NULL,
      \`draftQuestionId\` char(36) NULL,
      \`type\` varchar(32) NOT NULL,
      \`storageKey\` varchar(512) NOT NULL,
      \`sha256\` char(64) NOT NULL,
      \`size\` bigint unsigned NOT NULL,
      \`expiresAt\` datetime(3) NOT NULL,
      \`createdAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
      \`updatedAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
      KEY \`idx_import_artifact_draft\` (\`draftQuestionId\`),
      KEY \`idx_import_artifact_job_draft\` (\`jobId\`, \`draftQuestionId\`),
      KEY \`idx_import_artifact_expiry\` (\`expiresAt\`),
      CONSTRAINT \`chk_import_artifact_type\` CHECK (\`type\` IN ('source_pdf', 'question_image')),
      CONSTRAINT \`fk_import_artifact_job\` FOREIGN KEY (\`jobId\`) REFERENCES \`import_jobs\` (\`id\`) ON DELETE CASCADE,
      CONSTRAINT \`fk_import_artifact_draft_owner\` FOREIGN KEY (\`jobId\`, \`draftQuestionId\`) REFERENCES \`import_draft_questions\` (\`jobId\`, \`id\`) ON DELETE CASCADE,
      PRIMARY KEY (\`id\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`);
  }

  async down(queryRunner: QueryRunner): Promise<void> {
    for (const table of [
      'import_artifacts',
      'import_draft_questions',
      'import_upload_parts',
      'import_jobs'
    ]) {
      await queryRunner.query(`DROP TABLE IF EXISTS \`${table}\``);
    }
    await queryRunner.query('ALTER TABLE `devices` DROP INDEX `uq_device_user_id`');
  }
}
