import { Injectable } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';
import { AccountStore, StoredHuaweiIdentity, UserRecord } from '../auth/auth.contracts';
import { HuaweiIdentityEntity, UserEntity } from './entities';

@Injectable()
export class TypeOrmAccountStore implements AccountStore {
  constructor(@InjectDataSource() private readonly dataSource: DataSource) {}

  async findOrCreateHuaweiUser(identity: StoredHuaweiIdentity): Promise<UserRecord> {
    const identityRepository = this.dataSource.getRepository(HuaweiIdentityEntity);
    const existing = await identityRepository.findOne({
      where: { unionIdHash: identity.unionIdHash }
    });
    if (existing !== null) {
      return { id: existing.userId };
    }

    try {
      return await this.dataSource.transaction(async (manager) => {
        const concurrent = await manager.findOne(HuaweiIdentityEntity, {
          where: { unionIdHash: identity.unionIdHash }
        });
        if (concurrent !== null) {
          return { id: concurrent.userId };
        }
        const user = manager.create(UserEntity, { status: 'active' });
        await manager.save(user);
        const huaweiIdentity = manager.create(HuaweiIdentityEntity, {
          userId: user.id,
          ...identity
        });
        await manager.save(huaweiIdentity);
        return { id: user.id };
      });
    } catch (error) {
      const raced = await identityRepository.findOne({
        where: { unionIdHash: identity.unionIdHash }
      });
      if (raced !== null) {
        return { id: raced.userId };
      }
      throw error;
    }
  }
}
