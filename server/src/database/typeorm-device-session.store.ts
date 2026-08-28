import { Injectable } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { randomUUID } from 'node:crypto';
import { DataSource, IsNull, MoreThan } from 'typeorm';
import { DeviceRecord, DeviceSessionStore } from '../auth/auth.contracts';
import { DeviceEntity, SessionEntity } from './entities';

@Injectable()
export class TypeOrmDeviceSessionStore implements DeviceSessionStore {
  private readonly refreshLifetimeMilliseconds = 30 * 24 * 60 * 60 * 1000;

  constructor(@InjectDataSource() private readonly dataSource: DataSource) {}

  async registerDevice(
    userId: string,
    deviceKey: string,
    deviceName: string
  ): Promise<DeviceRecord> {
    const repository = this.dataSource.getRepository(DeviceEntity);
    let device = await repository.findOne({ where: { userId, deviceKey } });
    const now = new Date();
    const sessionGeneration = randomUUID();
    if (device === null) {
      device = repository.create({
        userId,
        deviceKey,
        name: deviceName,
        sessionGeneration,
        lastSeenAt: now,
        revokedAt: null
      });
    } else {
      device.name = deviceName;
      device.sessionGeneration = sessionGeneration;
      device.lastSeenAt = now;
      device.revokedAt = null;
    }
    let saved: DeviceEntity;
    try {
      saved = await repository.save(device);
    } catch (error) {
      const raced = await repository.findOne({ where: { userId, deviceKey } });
      if (raced === null) {
        throw error;
      }
      raced.name = deviceName;
      raced.sessionGeneration = sessionGeneration;
      raced.lastSeenAt = now;
      raced.revokedAt = null;
      saved = await repository.save(raced);
    }
    return {
      id: saved.id,
      name: saved.name,
      sessionGeneration: saved.sessionGeneration
    };
  }

  async replaceRefreshToken(
    userId: string,
    deviceId: string,
    sessionGeneration: string,
    refreshTokenHash: string
  ): Promise<boolean> {
    const now = new Date();
    return this.dataSource.transaction(async (manager) => {
      const device = await manager.findOne(DeviceEntity, {
        where: { id: deviceId, userId, sessionGeneration, revokedAt: IsNull() },
        lock: { mode: 'pessimistic_write' }
      });
      if (device === null) {
        return false;
      }
      await manager.update(
        SessionEntity,
        { userId, deviceId, revokedAt: IsNull() },
        { revokedAt: now }
      );
      const session = manager.create(SessionEntity, {
        userId,
        deviceId,
        refreshTokenHash,
        expiresAt: new Date(now.getTime() + this.refreshLifetimeMilliseconds),
        revokedAt: null
      });
      await manager.save(session);
      return true;
    });
  }

  async rotateRefreshToken(
    userId: string,
    deviceId: string,
    sessionGeneration: string,
    previousRefreshTokenHash: string,
    nextRefreshTokenHash: string
  ): Promise<boolean> {
    const now = new Date();
    return this.dataSource.transaction(async (manager) => {
      const device = await manager.findOne(DeviceEntity, {
        where: { id: deviceId, userId, sessionGeneration, revokedAt: IsNull() },
        lock: { mode: 'pessimistic_write' }
      });
      if (device === null) {
        return false;
      }
      const consumed = await manager.update(
        SessionEntity,
        {
          userId,
          deviceId,
          refreshTokenHash: previousRefreshTokenHash,
          revokedAt: IsNull(),
          expiresAt: MoreThan(now)
        },
        { revokedAt: now }
      );
      if (consumed.affected !== 1) {
        return false;
      }
      const session = manager.create(SessionEntity, {
        userId,
        deviceId,
        refreshTokenHash: nextRefreshTokenHash,
        expiresAt: new Date(now.getTime() + this.refreshLifetimeMilliseconds),
        revokedAt: null
      });
      await manager.save(session);
      return true;
    });
  }

  async revokeDeviceWithRefreshToken(
    userId: string,
    deviceId: string,
    sessionGeneration: string,
    refreshTokenHash: string
  ): Promise<boolean> {
    const now = new Date();
    return this.dataSource.transaction(async (manager) => {
      const device = await manager.findOne(DeviceEntity, {
        where: { id: deviceId, userId, sessionGeneration, revokedAt: IsNull() },
        lock: { mode: 'pessimistic_write' }
      });
      if (device === null) {
        return false;
      }
      const consumed = await manager.update(
        SessionEntity,
        {
          userId,
          deviceId,
          refreshTokenHash,
          revokedAt: IsNull(),
          expiresAt: MoreThan(now)
        },
        { revokedAt: now }
      );
      if (consumed.affected !== 1) {
        return false;
      }
      await manager.update(DeviceEntity, { id: deviceId, userId }, { revokedAt: now });
      await manager.update(
        SessionEntity,
        { userId, deviceId, revokedAt: IsNull() },
        { revokedAt: now }
      );
      return true;
    });
  }

  async isDeviceActive(
    userId: string,
    deviceId: string,
    sessionGeneration: string
  ): Promise<boolean> {
    const device = await this.dataSource.getRepository(DeviceEntity).findOne({
      where: { id: deviceId, userId, sessionGeneration, revokedAt: IsNull() }
    });
    return device !== null;
  }
}
