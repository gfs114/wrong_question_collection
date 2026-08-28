import { MigrationInterface, QueryRunner } from 'typeorm';

export class InitialSchema1760000000000 implements MigrationInterface {
  name = 'InitialSchema1760000000000';

  async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`CREATE TABLE \`users\` (
      \`id\` char(36) NOT NULL,
      \`status\` varchar(24) NOT NULL DEFAULT 'active',
      \`createdAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
      \`updatedAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
      PRIMARY KEY (\`id\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`);

    await queryRunner.query(`CREATE TABLE \`huawei_identities\` (
      \`id\` char(36) NOT NULL,
      \`userId\` char(36) NOT NULL,
      \`unionIdHash\` char(64) NOT NULL,
      \`encryptedUnionId\` text NOT NULL,
      \`encryptedOpenId\` text NULL,
      \`createdAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
      \`updatedAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
      UNIQUE KEY \`uq_huawei_identity_union_hash\` (\`unionIdHash\`),
      KEY \`idx_huawei_identity_user\` (\`userId\`),
      CONSTRAINT \`fk_huawei_identity_user\` FOREIGN KEY (\`userId\`) REFERENCES \`users\` (\`id\`) ON DELETE CASCADE,
      PRIMARY KEY (\`id\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`);

    await queryRunner.query(`CREATE TABLE \`devices\` (
      \`id\` char(36) NOT NULL,
      \`userId\` char(36) NOT NULL,
      \`deviceKey\` varchar(128) NOT NULL,
      \`name\` varchar(128) NOT NULL,
      \`sessionGeneration\` char(36) NOT NULL,
      \`lastSeenAt\` datetime(3) NOT NULL,
      \`revokedAt\` datetime(3) NULL,
      \`createdAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
      \`updatedAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
      UNIQUE KEY \`uq_device_user_key\` (\`userId\`, \`deviceKey\`),
      KEY \`idx_device_user\` (\`userId\`),
      CONSTRAINT \`fk_device_user\` FOREIGN KEY (\`userId\`) REFERENCES \`users\` (\`id\`) ON DELETE CASCADE,
      PRIMARY KEY (\`id\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`);

    await queryRunner.query(`CREATE TABLE \`sessions\` (
      \`id\` char(36) NOT NULL,
      \`userId\` char(36) NOT NULL,
      \`deviceId\` char(36) NOT NULL,
      \`refreshTokenHash\` char(64) NOT NULL,
      \`expiresAt\` datetime(3) NOT NULL,
      \`revokedAt\` datetime(3) NULL,
      \`createdAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
      \`updatedAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
      UNIQUE KEY \`uq_session_refresh_hash\` (\`refreshTokenHash\`),
      KEY \`idx_session_user\` (\`userId\`),
      KEY \`idx_session_device\` (\`deviceId\`),
      CONSTRAINT \`fk_session_user\` FOREIGN KEY (\`userId\`) REFERENCES \`users\` (\`id\`) ON DELETE CASCADE,
      CONSTRAINT \`fk_session_device\` FOREIGN KEY (\`deviceId\`) REFERENCES \`devices\` (\`id\`) ON DELETE CASCADE,
      PRIMARY KEY (\`id\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`);

    await queryRunner.query(`CREATE TABLE \`question_banks\` (
      \`id\` char(36) NOT NULL,
      \`userId\` char(36) NOT NULL,
      \`clientId\` char(36) NOT NULL,
      \`name\` varchar(255) NOT NULL,
      \`subject\` varchar(64) NOT NULL,
      \`version\` int unsigned NOT NULL DEFAULT 1,
      \`deletedAt\` datetime(3) NULL,
      \`createdAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
      \`updatedAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
      UNIQUE KEY \`uq_bank_user_client\` (\`userId\`, \`clientId\`),
      KEY \`idx_bank_user\` (\`userId\`),
      CONSTRAINT \`fk_bank_user\` FOREIGN KEY (\`userId\`) REFERENCES \`users\` (\`id\`) ON DELETE CASCADE,
      PRIMARY KEY (\`id\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`);

    await queryRunner.query(`CREATE TABLE \`questions\` (
      \`id\` char(36) NOT NULL,
      \`userId\` char(36) NOT NULL,
      \`bankId\` char(36) NOT NULL,
      \`clientId\` char(36) NOT NULL,
      \`type\` varchar(32) NOT NULL DEFAULT 'single_choice',
      \`question\` longtext NOT NULL,
      \`options\` json NULL,
      \`answer\` longtext NULL,
      \`analysis\` longtext NULL,
      \`version\` int unsigned NOT NULL DEFAULT 1,
      \`deletedAt\` datetime(3) NULL,
      \`createdAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
      \`updatedAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
      UNIQUE KEY \`uq_question_user_client\` (\`userId\`, \`clientId\`),
      KEY \`idx_question_user\` (\`userId\`),
      KEY \`idx_question_bank\` (\`bankId\`),
      CONSTRAINT \`fk_question_user\` FOREIGN KEY (\`userId\`) REFERENCES \`users\` (\`id\`) ON DELETE CASCADE,
      CONSTRAINT \`fk_question_bank\` FOREIGN KEY (\`bankId\`) REFERENCES \`question_banks\` (\`id\`) ON DELETE CASCADE,
      PRIMARY KEY (\`id\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`);

    await queryRunner.query(`CREATE TABLE \`wrong_questions\` (
      \`id\` char(36) NOT NULL,
      \`userId\` char(36) NOT NULL,
      \`questionClientId\` char(36) NOT NULL,
      \`status\` varchar(24) NOT NULL DEFAULT 'pending',
      \`version\` int unsigned NOT NULL DEFAULT 1,
      \`deletedAt\` datetime(3) NULL,
      \`createdAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
      \`updatedAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
      UNIQUE KEY \`uq_wrong_question_user_client\` (\`userId\`, \`questionClientId\`),
      KEY \`idx_wrong_question_user\` (\`userId\`),
      CONSTRAINT \`fk_wrong_question_user\` FOREIGN KEY (\`userId\`) REFERENCES \`users\` (\`id\`) ON DELETE CASCADE,
      PRIMARY KEY (\`id\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`);

    await queryRunner.query(`CREATE TABLE \`review_records\` (
      \`id\` char(36) NOT NULL,
      \`userId\` char(36) NOT NULL,
      \`questionClientId\` char(36) NOT NULL,
      \`clientEventId\` char(36) NOT NULL,
      \`result\` varchar(24) NOT NULL,
      \`reviewedAt\` datetime(3) NOT NULL,
      \`createdAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
      \`updatedAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
      UNIQUE KEY \`uq_review_user_event\` (\`userId\`, \`clientEventId\`),
      KEY \`idx_review_user\` (\`userId\`),
      CONSTRAINT \`fk_review_user\` FOREIGN KEY (\`userId\`) REFERENCES \`users\` (\`id\`) ON DELETE CASCADE,
      PRIMARY KEY (\`id\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`);

    await queryRunner.query(`CREATE TABLE \`sync_operations\` (
      \`id\` char(36) NOT NULL,
      \`userId\` char(36) NOT NULL,
      \`operationId\` char(36) NOT NULL,
      \`entityType\` varchar(32) NOT NULL,
      \`entityId\` char(36) NOT NULL,
      \`operationType\` varchar(16) NOT NULL,
      \`serverSequence\` bigint unsigned NOT NULL AUTO_INCREMENT,
      \`payload\` json NOT NULL,
      \`createdAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
      \`updatedAt\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
      UNIQUE KEY \`uq_sync_operation_user_id\` (\`userId\`, \`operationId\`),
      UNIQUE KEY \`uq_sync_operation_sequence\` (\`serverSequence\`),
      KEY \`idx_sync_operation_user_sequence\` (\`userId\`, \`serverSequence\`),
      CONSTRAINT \`fk_sync_operation_user\` FOREIGN KEY (\`userId\`) REFERENCES \`users\` (\`id\`) ON DELETE CASCADE,
      PRIMARY KEY (\`id\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`);
  }

  async down(queryRunner: QueryRunner): Promise<void> {
    for (const table of [
      'sync_operations',
      'review_records',
      'wrong_questions',
      'questions',
      'question_banks',
      'sessions',
      'devices',
      'huawei_identities',
      'users'
    ]) {
      await queryRunner.query(`DROP TABLE IF EXISTS \`${table}\``);
    }
  }
}
