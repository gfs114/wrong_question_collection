import { JwtService } from '@nestjs/jwt';
import { TokenService } from './token.service';

describe('TokenService', () => {
  const accessSecret = 'access-secret-with-at-least-32-characters';
  const refreshSecret = 'refresh-secret-with-at-least-32-characters';
  const jwt = new JwtService();

  it('issues distinct access and refresh tokens with bound user and device claims', async () => {
    const service = new TokenService(jwt, accessSecret, refreshSecret);

    const tokens = await service.issue('user-1', 'device-1', 'generation-1');
    const access = await jwt.verifyAsync(tokens.accessToken, { secret: accessSecret });
    const refresh = await jwt.verifyAsync(tokens.refreshToken, { secret: refreshSecret });

    expect(access).toMatchObject({
      sub: 'user-1',
      deviceId: 'device-1',
      sessionGeneration: 'generation-1',
      tokenType: 'access'
    });
    expect(refresh).toMatchObject({
      sub: 'user-1',
      deviceId: 'device-1',
      sessionGeneration: 'generation-1',
      tokenType: 'refresh'
    });
    expect(tokens.accessToken).not.toBe(tokens.refreshToken);
  });

  it('accepts only refresh tokens in the refresh verifier', async () => {
    const service = new TokenService(jwt, accessSecret, refreshSecret);
    const tokens = await service.issue('user-1', 'device-1', 'generation-1');

    await expect(service.verifyRefresh(tokens.refreshToken)).resolves.toMatchObject({
      userId: 'user-1',
      deviceId: 'device-1',
      sessionGeneration: 'generation-1'
    });
    await expect(service.verifyRefresh(tokens.accessToken)).rejects.toThrow();
  });

  it('accepts only access tokens in the access verifier', async () => {
    const service = new TokenService(jwt, accessSecret, refreshSecret);
    const tokens = await service.issue('user-1', 'device-1', 'generation-1');

    await expect(service.verifyAccess(tokens.accessToken)).resolves.toEqual({
      userId: 'user-1',
      deviceId: 'device-1',
      sessionGeneration: 'generation-1'
    });
    await expect(service.verifyAccess(tokens.refreshToken)).rejects.toThrow();
  });

  it('hashes refresh tokens before persistence', async () => {
    const service = new TokenService(jwt, accessSecret, refreshSecret);
    const tokens = await service.issue('user-1', 'device-1', 'generation-1');

    expect(service.hashRefreshToken(tokens.refreshToken)).toHaveLength(64);
    expect(service.hashRefreshToken(tokens.refreshToken)).not.toBe(tokens.refreshToken);
    expect(service.hashRefreshToken(tokens.refreshToken)).toBe(
      service.hashRefreshToken(tokens.refreshToken)
    );
  });
});
