import { DataSource } from 'typeorm';
import { HuaweiIdentityEntity, UserEntity } from './entities';
import { TypeOrmAccountStore } from './typeorm-account.store';

describe('TypeOrmAccountStore', () => {
  it('returns the existing user for a known Huawei identity', async () => {
    const dataSource = {
      getRepository: () => ({
        findOne: async () => ({ userId: 'existing-user' })
      })
    } as unknown as DataSource;
    const store = new TypeOrmAccountStore(dataSource);

    await expect(
      store.findOrCreateHuaweiUser({
        unionIdHash: 'a'.repeat(64),
        encryptedUnionId: 'encrypted-union',
        encryptedOpenId: null
      })
    ).resolves.toEqual({ id: 'existing-user' });
  });

  it('creates a user and encrypted identity in one transaction', async () => {
    const saved: object[] = [];
    const manager = {
      findOne: async () => null,
      create: (entity: Function, values: object) =>
        entity === UserEntity ? Object.assign(new UserEntity(), { id: 'new-user' }, values) :
          Object.assign(new HuaweiIdentityEntity(), { id: 'identity-1' }, values),
      save: async (value: object) => {
        saved.push(value);
        return value;
      }
    };
    const dataSource = {
      getRepository: () => ({ findOne: async () => null }),
      transaction: async (work: (value: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource;
    const store = new TypeOrmAccountStore(dataSource);

    await expect(
      store.findOrCreateHuaweiUser({
        unionIdHash: 'b'.repeat(64),
        encryptedUnionId: 'encrypted-union',
        encryptedOpenId: 'encrypted-open'
      })
    ).resolves.toEqual({ id: 'new-user' });
    expect(saved).toHaveLength(2);
    expect(saved[1]).toMatchObject({
      userId: 'new-user',
      unionIdHash: 'b'.repeat(64),
      encryptedUnionId: 'encrypted-union',
      encryptedOpenId: 'encrypted-open'
    });
  });
});
