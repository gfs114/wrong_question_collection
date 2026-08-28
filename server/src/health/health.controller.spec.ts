import { HealthController } from './health.controller';
import { HealthService } from './health.service';
import { DataSource } from 'typeorm';

describe('HealthController', () => {
  it('exposes liveness and database readiness separately', async () => {
    const controller = new HealthController(
      new HealthService({ query: async () => [{ ok: 1 }] } as unknown as DataSource)
    );

    expect(controller.getStatus()).toEqual({
      status: 'ok',
      service: 'wrong-question-api'
    });
    await expect(controller.getReadiness()).resolves.toEqual({
      status: 'ok',
      service: 'wrong-question-api',
      database: 'ready'
    });
  });
});
