import { AuthenticatedRequest } from '../auth/access-token.guard';
import { SyncController } from './sync.controller';
import { SyncService } from './sync.service';

describe('SyncController', () => {
  it('uses the authenticated principal instead of accepting a user id from input', async () => {
    const calls: unknown[][] = [];
    const service = {
      push: async (...args: unknown[]) => {
        calls.push(args);
        return { operations: [] };
      },
      pull: async (...args: unknown[]) => {
        calls.push(args);
        return { operations: [], nextCursor: '0', hasMore: false };
      }
    } as unknown as SyncService;
    const controller = new SyncController(service);
    const request = {
      headers: {},
      auth: { userId: 'server-user-1', deviceId: 'device-1' }
    } as AuthenticatedRequest;

    await controller.push(request, { operations: [] });
    await controller.pull(request, '10', '50');

    expect(calls).toEqual([
      ['server-user-1', []],
      ['server-user-1', '10', 50]
    ]);
  });
});
