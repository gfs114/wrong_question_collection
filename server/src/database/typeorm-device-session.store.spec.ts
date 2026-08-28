import { DataSource } from 'typeorm';
import { DeviceEntity, SessionEntity } from './entities';
import { TypeOrmDeviceSessionStore } from './typeorm-device-session.store';

describe('TypeOrmDeviceSessionStore', () => {
  it('reactivates and updates an existing device', async () => {
    const existing = Object.assign(new DeviceEntity(), {
      id: 'device-1',
      userId: 'user-1',
      deviceKey: 'device-key',
      name: 'Old name',
      sessionGeneration: 'old-generation',
      revokedAt: new Date()
    });
    let saved: DeviceEntity | null = null;
    const dataSource = {
      getRepository: () => ({
        findOne: async () => existing,
        save: async (device: DeviceEntity) => {
          saved = device;
          return device;
        }
      })
    } as unknown as DataSource;
    const store = new TypeOrmDeviceSessionStore(dataSource);

    await expect(store.registerDevice('user-1', 'device-key', 'WEB-W00')).resolves.toEqual({
      id: 'device-1',
      name: 'WEB-W00',
      sessionGeneration: expect.any(String)
    });
    expect(saved).toMatchObject({ name: 'WEB-W00', revokedAt: null });
    expect((saved as unknown as DeviceEntity).sessionGeneration).not.toBe('old-generation');
  });

  it('creates a previously unknown device', async () => {
    const repository = {
      findOne: async () => null,
      create: (values: object) => Object.assign(new DeviceEntity(), { id: 'device-2' }, values),
      save: async (device: DeviceEntity) => device
    };
    const dataSource = {
      getRepository: () => repository
    } as unknown as DataSource;
    const store = new TypeOrmDeviceSessionStore(dataSource);

    await expect(store.registerDevice('user-1', 'new-key', 'New device')).resolves.toEqual({
      id: 'device-2',
      name: 'New device',
      sessionGeneration: expect.any(String)
    });
  });

  it('recovers when another login inserts the same new device concurrently', async () => {
    const raced = Object.assign(new DeviceEntity(), {
      id: 'device-raced',
      userId: 'user-1',
      deviceKey: 'new-key',
      name: 'Other login',
      sessionGeneration: 'other-generation',
      revokedAt: null
    });
    let findCalls = 0;
    let saveCalls = 0;
    const repository = {
      findOne: async () => (++findCalls === 1 ? null : raced),
      create: (values: object) => Object.assign(new DeviceEntity(), values),
      save: async (device: DeviceEntity) => {
        if (++saveCalls === 1) {
          throw new Error('duplicate device');
        }
        return device;
      }
    };
    const dataSource = { getRepository: () => repository } as unknown as DataSource;

    await expect(
      new TypeOrmDeviceSessionStore(dataSource).registerDevice(
        'user-1',
        'new-key',
        'This login'
      )
    ).resolves.toMatchObject({ id: 'device-raced', name: 'This login' });
    expect(raced.sessionGeneration).not.toBe('other-generation');
  });

  it('revokes previous sessions and saves only a refresh token hash', async () => {
    const updates: Array<{ target: Function; criteria: object; values: object }> = [];
    const saved: object[] = [];
    const manager = {
      findOne: async () => Object.assign(new DeviceEntity(), {
        id: 'device-1',
        userId: 'user-1',
        sessionGeneration: 'generation-1',
        revokedAt: null
      }),
      update: async (target: Function, criteria: object, values: object) => {
        updates.push({ target, criteria, values });
      },
      create: (_target: Function, values: object) => Object.assign(new SessionEntity(), values),
      save: async (value: object) => {
        saved.push(value);
        return value;
      }
    };
    const dataSource = {
      transaction: async (work: (value: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource;
    const store = new TypeOrmDeviceSessionStore(dataSource);

    await expect(
      store.replaceRefreshToken('user-1', 'device-1', 'generation-1', 'a'.repeat(64))
    ).resolves.toBe(true);

    expect(updates[0]).toMatchObject({ target: SessionEntity });
    expect(saved[0]).toMatchObject({
      userId: 'user-1',
      deviceId: 'device-1',
      refreshTokenHash: 'a'.repeat(64),
      revokedAt: null
    });
    expect((saved[0] as SessionEntity).expiresAt.getTime()).toBeGreaterThan(Date.now());
  });

  it('atomically consumes the previous refresh token before saving the next one', async () => {
    const saved: SessionEntity[] = [];
    let affected = 1;
    const manager = {
      findOne: async () => Object.assign(new DeviceEntity(), {
        id: 'device-1',
        userId: 'user-1',
        sessionGeneration: 'generation-1',
        revokedAt: null
      }),
      update: async () => ({ affected }),
      create: (_target: Function, values: object) => Object.assign(new SessionEntity(), values),
      save: async (value: SessionEntity) => {
        saved.push(value);
        return value;
      }
    };
    const dataSource = {
      transaction: async (work: (value: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource;
    const store = new TypeOrmDeviceSessionStore(dataSource);

    await expect(
      store.rotateRefreshToken(
        'user-1',
        'device-1',
        'generation-1',
        'a'.repeat(64),
        'b'.repeat(64)
      )
    ).resolves.toBe(true);
    expect(saved[0]).toMatchObject({ refreshTokenHash: 'b'.repeat(64), revokedAt: null });

    affected = 0;
    await expect(
      store.rotateRefreshToken(
        'user-1',
        'device-1',
        'generation-1',
        'a'.repeat(64),
        'c'.repeat(64)
      )
    ).resolves.toBe(false);
    expect(saved).toHaveLength(1);
  });

  it('revokes a device only when the presented refresh token is still active', async () => {
    const updates: Function[] = [];
    let affected = 1;
    const manager = {
      findOne: async () => Object.assign(new DeviceEntity(), {
        id: 'device-1',
        userId: 'user-1',
        sessionGeneration: 'generation-1',
        revokedAt: null
      }),
      update: async (target: Function) => {
        updates.push(target);
        return { affected };
      }
    };
    const dataSource = {
      transaction: async (work: (value: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource;
    const store = new TypeOrmDeviceSessionStore(dataSource);

    await expect(
      store.revokeDeviceWithRefreshToken(
        'user-1',
        'device-1',
        'generation-1',
        'a'.repeat(64)
      )
    ).resolves.toBe(true);

    expect(updates).toEqual([SessionEntity, DeviceEntity, SessionEntity]);

    affected = 0;
    updates.length = 0;
    await expect(
      store.revokeDeviceWithRefreshToken(
        'user-1',
        'device-1',
        'generation-1',
        'b'.repeat(64)
      )
    ).resolves.toBe(false);
    expect(updates).toEqual([SessionEntity]);
  });

  it('checks device revocation when authorizing access tokens', async () => {
    let device: DeviceEntity | null = Object.assign(new DeviceEntity(), {
      id: 'device-1',
      userId: 'user-1',
      revokedAt: null
    });
    const dataSource = {
      getRepository: () => ({ findOne: async () => device })
    } as unknown as DataSource;
    const store = new TypeOrmDeviceSessionStore(dataSource);

    await expect(
      store.isDeviceActive('user-1', 'device-1', 'generation-1')
    ).resolves.toBe(true);
    device = null;
    await expect(
      store.isDeviceActive('user-1', 'device-1', 'generation-1')
    ).resolves.toBe(false);
  });
});
