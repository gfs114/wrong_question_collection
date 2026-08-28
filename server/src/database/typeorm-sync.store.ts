import { BadRequestException, Injectable, UnauthorizedException } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { randomUUID } from 'node:crypto';
import { DataSource, EntityManager, IsNull, MoreThan } from 'typeorm';
import {
  PullResult,
  StoredSyncOperation,
  SyncEntityType,
  SyncOperationInput,
  SyncOperationType,
  SyncStore
} from '../sync/sync.contracts';
import {
  QuestionBankEntity,
  QuestionEntity,
  ReviewRecordEntity,
  SyncOperationEntity,
  UserEntity,
  WrongQuestionEntity
} from './entities';

function requiredString(payload: Record<string, unknown>, key: string): string {
  const value = payload[key];
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new BadRequestException(`${key} is required for this sync operation`);
  }
  return value.trim();
}

function optionalString(payload: Record<string, unknown>, key: string): string | null {
  const value = payload[key];
  return typeof value === 'string' && value.length > 0 ? value : null;
}

function optionalStringRecord(
  payload: Record<string, unknown>,
  key: string
): Record<string, string> | null {
  const value = payload[key];
  if (value === null || value === undefined) {
    return null;
  }
  if (typeof value !== 'object' || Array.isArray(value)) {
    throw new BadRequestException(`${key} must be an object`);
  }
  const result: Record<string, string> = {};
  for (const [entryKey, entryValue] of Object.entries(value)) {
    if (typeof entryValue !== 'string') {
      throw new BadRequestException(`${key} values must be strings`);
    }
    result[entryKey] = entryValue;
  }
  return result;
}

function storedOperation(entity: SyncOperationEntity): StoredSyncOperation {
  return {
    operationId: entity.operationId,
    entityType: entity.entityType as SyncEntityType,
    entityId: entity.entityId,
    operationType: entity.operationType as SyncOperationType,
    payload: entity.payload,
    serverSequence: String(entity.serverSequence)
  };
}

function canonicalPayload(operation: SyncOperationInput): Record<string, unknown> {
  if (operation.entityType === 'wrong_question') {
    return { ...operation.payload, questionClientId: operation.entityId };
  }
  return operation.payload;
}

@Injectable()
export class TypeOrmSyncStore implements SyncStore {
  constructor(@InjectDataSource() private readonly dataSource: DataSource) {}

  apply(userId: string, operations: SyncOperationInput[]): Promise<StoredSyncOperation[]> {
    return this.dataSource.transaction((manager) => this.applyInTransaction(manager, userId, operations));
  }

  /** Reuses the canonical materialization/event semantics inside a caller-owned transaction. */
  async applyInTransaction(
    manager: EntityManager,
    userId: string,
    operations: SyncOperationInput[]
  ): Promise<StoredSyncOperation[]> {
      const user = await manager.findOne(UserEntity, {
        where: { id: userId },
        lock: { mode: 'pessimistic_write' }
      });
      if (user === null) {
        throw new UnauthorizedException('The synchronized user no longer exists');
      }
      const accepted: StoredSyncOperation[] = [];
      for (const operation of operations) {
        const previous = await manager.findOne(SyncOperationEntity, {
          where: { userId, operationId: operation.operationId }
        });
        if (previous !== null) {
          accepted.push(storedOperation(previous));
          continue;
        }
        await this.materialize(manager, userId, operation);
        const event = manager.create(SyncOperationEntity, {
          id: randomUUID(),
          userId,
          operationId: operation.operationId,
          entityType: operation.entityType,
          entityId: operation.entityId,
          operationType: operation.operationType,
          payload: canonicalPayload(operation)
        });
        const savedEvent = await manager.save(event);
        accepted.push(storedOperation(savedEvent));
      }
      return accepted;
  }

  async pull(userId: string, cursor: string, limit: number): Promise<PullResult> {
    const events = await this.dataSource.getRepository(SyncOperationEntity).find({
      where: { userId, serverSequence: MoreThan(cursor) },
      order: { serverSequence: 'ASC' },
      take: limit + 1
    });
    const hasMore = events.length > limit;
    const page = events.slice(0, limit).map(storedOperation);
    return {
      operations: page,
      nextCursor: page.length === 0 ? cursor : page[page.length - 1].serverSequence,
      hasMore
    };
  }

  private async materialize(
    manager: EntityManager,
    userId: string,
    operation: SyncOperationInput
  ): Promise<void> {
    switch (operation.entityType) {
      case 'question_bank':
        await this.materializeBank(manager, userId, operation);
        return;
      case 'question':
        await this.materializeQuestion(manager, userId, operation);
        return;
      case 'wrong_question':
        await this.materializeWrongQuestion(manager, userId, operation);
        return;
      case 'review_record':
        await this.materializeReview(manager, userId, operation);
        return;
    }
  }

  private async materializeBank(
    manager: EntityManager,
    userId: string,
    operation: SyncOperationInput
  ): Promise<void> {
    let bank = await manager.findOne(QuestionBankEntity, {
      where: { userId, clientId: operation.entityId }
    });
    if (operation.operationType === 'delete') {
      if (bank !== null) {
        bank.deletedAt = new Date();
        bank.version += 1;
        await manager.save(bank);
      }
      return;
    }
    if (bank === null) {
      bank = manager.create(QuestionBankEntity, {
        id: randomUUID(),
        userId,
        clientId: operation.entityId,
        version: 0,
        deletedAt: null
      });
    }
    bank.name = requiredString(operation.payload, 'name');
    bank.subject = requiredString(operation.payload, 'subject');
    bank.version += 1;
    bank.deletedAt = null;
    await manager.save(bank);
  }

  private async materializeQuestion(
    manager: EntityManager,
    userId: string,
    operation: SyncOperationInput
  ): Promise<void> {
    let question = await manager.findOne(QuestionEntity, {
      where: { userId, clientId: operation.entityId }
    });
    if (operation.operationType === 'delete') {
      if (question !== null) {
        question.deletedAt = new Date();
        question.version += 1;
        await manager.save(question);
      }
      return;
    }
    const bankClientId = requiredString(operation.payload, 'bankClientId');
    const bank = await manager.findOne(QuestionBankEntity, {
      where: { userId, clientId: bankClientId, deletedAt: IsNull() }
    });
    if (bank === null) {
      throw new BadRequestException('The question bank must be synchronized first');
    }
    if (question === null) {
      question = manager.create(QuestionEntity, {
        id: randomUUID(),
        userId,
        clientId: operation.entityId,
        version: 0,
        deletedAt: null
      });
    }
    question.bankId = bank.id;
    question.type = optionalString(operation.payload, 'type') ?? 'single_choice';
    question.question = requiredString(operation.payload, 'question');
    question.options = optionalStringRecord(operation.payload, 'options');
    question.answer = optionalString(operation.payload, 'answer');
    question.analysis = optionalString(operation.payload, 'analysis');
    question.version += 1;
    question.deletedAt = null;
    await manager.save(question);
  }

  private async materializeWrongQuestion(
    manager: EntityManager,
    userId: string,
    operation: SyncOperationInput
  ): Promise<void> {
    const questionClientId = operation.entityId;
    let wrongQuestion = await manager.findOne(WrongQuestionEntity, {
      where: { userId, questionClientId }
    });
    if (operation.operationType === 'delete') {
      if (wrongQuestion !== null) {
        wrongQuestion.deletedAt = new Date();
        wrongQuestion.version += 1;
        await manager.save(wrongQuestion);
      }
      return;
    }
    if (wrongQuestion === null) {
      wrongQuestion = manager.create(WrongQuestionEntity, {
        id: randomUUID(),
        userId,
        questionClientId,
        version: 0,
        deletedAt: null
      });
    }
    wrongQuestion.status = requiredString(operation.payload, 'status');
    wrongQuestion.version += 1;
    wrongQuestion.deletedAt = null;
    await manager.save(wrongQuestion);
  }

  private async materializeReview(
    manager: EntityManager,
    userId: string,
    operation: SyncOperationInput
  ): Promise<void> {
    const questionClientId = requiredString(operation.payload, 'questionClientId');
    const result = requiredString(operation.payload, 'result');
    const reviewedAt = new Date(requiredString(operation.payload, 'reviewedAt'));
    if (Number.isNaN(reviewedAt.getTime())) {
      throw new BadRequestException('reviewedAt must be an ISO date');
    }
    const existing = await manager.findOne(ReviewRecordEntity, {
      where: { userId, clientEventId: operation.entityId }
    });
    if (existing !== null) {
      if (
        existing.questionClientId !== questionClientId ||
        existing.result !== result ||
        existing.reviewedAt.getTime() !== reviewedAt.getTime()
      ) {
        throw new BadRequestException(
          'Review record conflicts with an existing append-only event'
        );
      }
      return;
    }
    const review = manager.create(ReviewRecordEntity, {
      id: randomUUID(),
      userId,
      clientEventId: operation.entityId,
      questionClientId,
      result,
      reviewedAt
    });
    await manager.save(review);
  }
}
