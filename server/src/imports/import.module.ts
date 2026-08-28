import { Module } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { statfs } from 'node:fs/promises';
import { DataSource } from 'typeorm';
import { AuthModule } from '../auth/auth.module';
import { DEVICE_SESSION_STORE, DeviceSessionStore } from '../auth/auth.contracts';
import { TokenService } from '../auth/token.service';
import { DatabaseModule } from '../database/database.module';
import { ImportController } from './import.controller';
import { ImportCleanupService } from './import-cleanup.service';
import { ImportUploadAdmissionService } from './import-upload-admission.service';
import { TypeOrmImportRepository } from './import.repository';
import { ImportStorageService } from './import-storage.service';
import {
  IMPORT_REPOSITORY,
  IMPORT_UPLOAD_LIMITS,
  effectiveImportPartBytes,
  ImportService,
  ImportUploadLimits
} from './import.service';

async function availableBytes(root: string): Promise<number> {
  const stats = await statfs(root, { bigint: true });
  const available = stats.bavail * stats.bsize;
  return available > BigInt(Number.MAX_SAFE_INTEGER)
    ? Number.MAX_SAFE_INTEGER
    : Number(available);
}

@Module({
  imports: [AuthModule, DatabaseModule],
  controllers: [ImportController],
  providers: [
    {
      provide: TypeOrmImportRepository,
      inject: [DataSource],
      useFactory: (dataSource: DataSource) => new TypeOrmImportRepository(dataSource)
    },
    { provide: IMPORT_REPOSITORY, useExisting: TypeOrmImportRepository },
    {
      provide: ImportUploadAdmissionService,
      inject: [TokenService, DEVICE_SESSION_STORE],
      useFactory: (tokens: TokenService, sessions: DeviceSessionStore) =>
        new ImportUploadAdmissionService(tokens, sessions)
    },
    {
      provide: IMPORT_UPLOAD_LIMITS,
      inject: [ConfigService],
      useFactory: (config: ConfigService): ImportUploadLimits => ({
        maxPdfBytes: config.getOrThrow<number>('IMPORT_MAX_PDF_BYTES'),
        partBytes: effectiveImportPartBytes(config.getOrThrow<number>('IMPORT_PART_BYTES'))
      })
    },
    {
      provide: ImportStorageService,
      inject: [ConfigService],
      useFactory: (config: ConfigService) => new ImportStorageService({
        root: config.getOrThrow<string>('IMPORT_STORAGE_ROOT'),
        maxPdfBytes: config.getOrThrow<number>('IMPORT_MAX_PDF_BYTES'),
        partBytes: effectiveImportPartBytes(config.getOrThrow<number>('IMPORT_PART_BYTES')),
        minFreeBytes: config.getOrThrow<number>('IMPORT_MIN_FREE_BYTES')
      }, availableBytes)
    },
    ImportService,
    ImportCleanupService
  ]
})
export class ImportsModule {}
