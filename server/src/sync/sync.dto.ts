import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  IsArray,
  IsIn,
  IsObject,
  IsUUID,
  ValidateNested
} from 'class-validator';
import { SyncEntityType, SyncOperationInput, SyncOperationType } from './sync.contracts';

export class SyncOperationDto implements SyncOperationInput {
  @IsUUID()
  operationId!: string;

  @IsIn(['question_bank', 'question', 'wrong_question', 'review_record'])
  entityType!: SyncEntityType;

  @IsUUID()
  entityId!: string;

  @IsIn(['upsert', 'delete'])
  operationType!: SyncOperationType;

  @IsObject()
  payload!: Record<string, unknown>;
}

export class SyncPushDto {
  @IsArray()
  @ArrayMaxSize(100)
  @ValidateNested({ each: true })
  @Type(() => SyncOperationDto)
  operations!: SyncOperationDto[];
}
