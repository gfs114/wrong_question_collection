import { QueryRunner } from 'typeorm';
import { CloudImportSchema1788000000000 } from './1788000000000-cloud-import-schema';

describe('CloudImportSchema1788000000000', () => {
  it('creates the cloud import tables with ownership, lifecycle, and foreign-key constraints', async () => {
    const statements: string[] = [];
    const queryRunner = {
      query: async (statement: string) => {
        statements.push(statement);
      }
    } as unknown as QueryRunner;

    await new CloudImportSchema1788000000000().up(queryRunner);

    const source = statements.join('\n');
    const statementByTable = new Map(
      statements.map((statement) => [statement.match(/CREATE TABLE `([^`]+)`/)?.[1], statement])
    );
    const requiredColumns: Record<string, string[]> = {
      import_jobs: [
        '`id` char(36) NOT NULL',
        '`userId` char(36) NOT NULL',
        '`deviceId` char(36) NOT NULL',
        '`bankName` varchar(255) NOT NULL',
        '`subject` varchar(64) NOT NULL',
        '`pageStart` int unsigned NOT NULL',
        '`pageEnd` int unsigned NOT NULL',
        "`status` varchar(24) NOT NULL DEFAULT 'uploading'",
        '`progressCurrent` int unsigned NOT NULL DEFAULT 0',
        '`progressTotal` int unsigned NOT NULL DEFAULT 0',
        '`sourceSha256` char(64) NOT NULL',
        '`sourceSize` bigint unsigned NOT NULL',
        '`partCount` int unsigned NOT NULL',
        '`retryCount` int unsigned NOT NULL DEFAULT 0',
        '`errorCode` varchar(64) NULL',
        '`claimedAt` datetime(3) NULL',
        '`expiresAt` datetime(3) NOT NULL',
        '`createdAt` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)',
        '`updatedAt` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3)'
      ],
      import_upload_parts: [
        '`id` char(36) NOT NULL',
        '`jobId` char(36) NOT NULL',
        '`partNumber` int unsigned NOT NULL',
        '`size` bigint unsigned NOT NULL',
        '`sha256` char(64) NOT NULL',
        '`storageKey` varchar(512) NOT NULL',
        '`createdAt` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)',
        '`updatedAt` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3)'
      ],
      import_draft_questions: [
        '`id` char(36) NOT NULL',
        '`jobId` char(36) NOT NULL',
        '`position` int unsigned NOT NULL',
        '`type` varchar(32) NOT NULL',
        '`question` longtext NOT NULL',
        '`options` json NULL',
        '`answer` longtext NULL',
        '`analysis` longtext NULL',
        '`pageStart` int unsigned NOT NULL',
        '`pageEnd` int unsigned NOT NULL',
        '`confidence` decimal(5,4) NOT NULL DEFAULT 0',
        '`reviewRequired` tinyint NOT NULL DEFAULT 1',
        '`createdAt` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)',
        '`updatedAt` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3)'
      ],
      import_artifacts: [
        '`id` char(36) NOT NULL',
        '`jobId` char(36) NOT NULL',
        '`draftQuestionId` char(36) NULL',
        '`type` varchar(32) NOT NULL',
        '`storageKey` varchar(512) NOT NULL',
        '`sha256` char(64) NOT NULL',
        '`size` bigint unsigned NOT NULL',
        '`expiresAt` datetime(3) NOT NULL',
        '`createdAt` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)',
        '`updatedAt` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3)'
      ]
    };

    for (const [table, columns] of Object.entries(requiredColumns)) {
      const statement = statementByTable.get(table);
      expect(statement).toContain(`CREATE TABLE \`${table}\``);
      for (const column of columns) {
        expect(statement).toContain(column);
      }
    }

    expect(source).toContain('ALTER TABLE `devices` ADD UNIQUE KEY `uq_device_user_id` (`userId`, `id`)');
    expect(source).not.toContain('KEY `idx_import_job_user` (`userId`)');
    expect(source).toContain('KEY `idx_import_job_device` (`deviceId`)');
    expect(source).toContain('KEY `idx_import_job_user_device` (`userId`, `deviceId`)');
    expect(source).toContain('KEY `idx_import_job_status_created` (`status`, `createdAt`)');
    expect(source).toContain('KEY `idx_import_job_expiry` (`expiresAt`)');
    expect(source).toContain('UNIQUE KEY `uq_import_part_job_number` (`jobId`, `partNumber`)');
    expect(source).not.toContain('KEY `idx_import_part_job` (`jobId`)');
    expect(source).not.toContain('KEY `idx_import_draft_job_position` (`jobId`, `position`)');
    expect(source).toContain('UNIQUE KEY `uq_import_draft_job_position` (`jobId`, `position`)');
    expect(source).toContain('UNIQUE KEY `uq_import_draft_job_id` (`jobId`, `id`)');
    expect(source).not.toContain('KEY `idx_import_artifact_job` (`jobId`)');
    expect(source).toContain('KEY `idx_import_artifact_draft` (`draftQuestionId`)');
    expect(source).toContain('KEY `idx_import_artifact_job_draft` (`jobId`, `draftQuestionId`)');
    expect(source).toContain('KEY `idx_import_artifact_expiry` (`expiresAt`)');
    expect(source).toContain('CONSTRAINT `fk_import_job_user` FOREIGN KEY (`userId`) REFERENCES `users` (`id`) ON DELETE CASCADE');
    expect(source).toContain('CONSTRAINT `fk_import_job_device_owner` FOREIGN KEY (`userId`, `deviceId`) REFERENCES `devices` (`userId`, `id`) ON DELETE CASCADE');
    expect(source).toContain('CONSTRAINT `fk_import_part_job` FOREIGN KEY (`jobId`) REFERENCES `import_jobs` (`id`) ON DELETE CASCADE');
    expect(source).toContain('CONSTRAINT `fk_import_draft_job` FOREIGN KEY (`jobId`) REFERENCES `import_jobs` (`id`) ON DELETE CASCADE');
    expect(source).toContain('CONSTRAINT `fk_import_artifact_job` FOREIGN KEY (`jobId`) REFERENCES `import_jobs` (`id`) ON DELETE CASCADE');
    expect(source).toContain('CONSTRAINT `fk_import_artifact_draft_owner` FOREIGN KEY (`jobId`, `draftQuestionId`) REFERENCES `import_draft_questions` (`jobId`, `id`) ON DELETE CASCADE');
    for (const check of [
      "CONSTRAINT `chk_import_job_status` CHECK (`status` IN ('uploading', 'queued', 'processing', 'review', 'confirmed', 'failed', 'cancelled', 'expired'))",
      'CONSTRAINT `chk_import_job_page_range` CHECK (`pageStart` >= 1 AND `pageEnd` >= `pageStart` AND `pageEnd` <= `pageStart` + 19)',
      'CONSTRAINT `chk_import_job_source_size` CHECK (`sourceSize` BETWEEN 1 AND 209715200)',
      'CONSTRAINT `chk_import_job_progress` CHECK (`progressCurrent` <= `progressTotal`)',
      'CONSTRAINT `chk_import_job_retry_count` CHECK (`retryCount` BETWEEN 0 AND 2)',
      'CONSTRAINT `chk_import_job_part_count` CHECK (`partCount` >= 0)',
      'CONSTRAINT `chk_import_part_number` CHECK (`partNumber` >= 0)',
      'CONSTRAINT `chk_import_draft_position` CHECK (`position` >= 0)',
      'CONSTRAINT `chk_import_draft_page_range` CHECK (`pageStart` >= 1 AND `pageEnd` >= `pageStart` AND `pageEnd` <= `pageStart` + 19)',
      'CONSTRAINT `chk_import_draft_confidence` CHECK (`confidence` BETWEEN 0 AND 1)',
      'CONSTRAINT `chk_import_draft_review_required` CHECK (`reviewRequired` IN (0, 1))',
      "CONSTRAINT `chk_import_artifact_type` CHECK (`type` IN ('source_pdf', 'question_image'))"
    ]) {
      expect(source).toContain(check);
    }
  });

  it('drops cloud import tables in reverse dependency order', async () => {
    const statements: string[] = [];
    const queryRunner = {
      query: async (statement: string) => {
        statements.push(statement);
      }
    } as unknown as QueryRunner;

    await new CloudImportSchema1788000000000().down(queryRunner);

    expect(statements.slice(0, 4).map((statement) => statement.match(/`([^`]+)`/)?.[1])).toEqual([
      'import_artifacts',
      'import_draft_questions',
      'import_upload_parts',
      'import_jobs'
    ]);
    expect(statements.at(-1)).toContain('ALTER TABLE `devices` DROP INDEX `uq_device_user_id`');
  });
});
