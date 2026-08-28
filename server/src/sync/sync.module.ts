import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { DatabaseModule } from '../database/database.module';
import { TypeOrmSyncStore } from '../database/typeorm-sync.store';
import { SYNC_STORE } from './sync.contracts';
import { SyncController } from './sync.controller';
import { SyncService } from './sync.service';

@Module({
  imports: [AuthModule, DatabaseModule],
  controllers: [SyncController],
  providers: [
    SyncService,
    { provide: SYNC_STORE, useExisting: TypeOrmSyncStore }
  ]
})
export class SyncModule {}
