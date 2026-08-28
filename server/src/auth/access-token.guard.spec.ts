import { ExecutionContext, UnauthorizedException } from '@nestjs/common';
import { AccessTokenGuard, AuthenticatedRequest } from './access-token.guard';
import { TokenService } from './token.service';
import { DeviceSessionStore } from './auth.contracts';

function contextFor(request: AuthenticatedRequest): ExecutionContext {
  return {
    switchToHttp: () => ({ getRequest: () => request })
  } as unknown as ExecutionContext;
}

describe('AccessTokenGuard', () => {
  it('verifies a bearer token and attaches the authenticated principal', async () => {
    const tokenService = {
      verifyAccess: async () => ({
        userId: 'user-1',
        deviceId: 'device-1',
        sessionGeneration: 'generation-1'
      })
    } as unknown as TokenService;
    const request = { headers: { authorization: 'Bearer access-token' } } as AuthenticatedRequest;
    const isDeviceActive = jest.fn().mockResolvedValue(true);
    const sessions = { isDeviceActive } as unknown as DeviceSessionStore;
    const guard = new AccessTokenGuard(tokenService, sessions);

    await expect(guard.canActivate(contextFor(request))).resolves.toBe(true);
    expect(request.auth).toEqual({
      userId: 'user-1',
      deviceId: 'device-1',
      sessionGeneration: 'generation-1'
    });
    expect(isDeviceActive).toHaveBeenCalledWith('user-1', 'device-1', 'generation-1');
  });

  it('rejects a request without one bearer token', async () => {
    const tokenService = {} as TokenService;
    const request = { headers: {} } as AuthenticatedRequest;
    const sessions = {} as DeviceSessionStore;
    const guard = new AccessTokenGuard(tokenService, sessions);

    await expect(guard.canActivate(contextFor(request))).rejects.toBeInstanceOf(
      UnauthorizedException
    );
  });

  it('rejects an otherwise valid token after its device is revoked', async () => {
    const tokenService = {
      verifyAccess: async () => ({
        userId: 'user-1',
        deviceId: 'device-1',
        sessionGeneration: 'old-generation'
      })
    } as unknown as TokenService;
    const sessions = { isDeviceActive: async () => false } as unknown as DeviceSessionStore;
    const request = { headers: { authorization: 'Bearer access-token' } } as AuthenticatedRequest;
    const guard = new AccessTokenGuard(tokenService, sessions);

    await expect(guard.canActivate(contextFor(request))).rejects.toBeInstanceOf(
      UnauthorizedException
    );
  });
});
