import { HealthService } from './health.service';
import { DataSource } from 'typeorm';

describe('HealthService', () => {
  it('returns a stable healthy response', () => {
    const service = new HealthService({} as DataSource);

    expect(service.getStatus()).toEqual({
      status: 'ok',
      service: 'wrong-question-api'
    });
  });

  it('reports readiness only after MySQL answers a probe', async () => {
    const query = jest.fn().mockResolvedValue([{ ok: 1 }]);
    const service = new HealthService({ query } as unknown as DataSource);

    await expect(service.getReadiness()).resolves.toEqual({
      status: 'ok',
      service: 'wrong-question-api',
      database: 'ready'
    });
    expect(query).toHaveBeenCalledWith('SELECT 1');
  });

  it('marks readiness unavailable when MySQL cannot answer', async () => {
    const service = new HealthService({
      query: async () => {
        throw new Error('connection lost');
      }
    } as unknown as DataSource);

    await expect(service.getReadiness()).rejects.toThrow('Database is not ready');
  });
});
