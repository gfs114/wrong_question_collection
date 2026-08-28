import { validate } from 'class-validator';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import { HuaweiLoginDto, RefreshTokenDto } from './auth.dto';

describe('auth HTTP boundary', () => {
  it('rejects empty Huawei login input', async () => {
    const input = Object.assign(new HuaweiLoginDto(), {
      authorizationCode: '',
      deviceKey: '',
      deviceName: ''
    });

    expect(await validate(input)).toHaveLength(3);
  });

  it('accepts a complete Huawei login input', async () => {
    const input = Object.assign(new HuaweiLoginDto(), {
      authorizationCode: 'authorization-code',
      deviceKey: 'device-key-1234',
      deviceName: 'WEB-W00'
    });

    expect(await validate(input)).toHaveLength(0);
  });

  it('delegates login, refresh, and logout without exposing service dependencies', async () => {
    const calls: string[] = [];
    const service = {
      loginWithHuawei: async () => {
        calls.push('login');
        return { accessToken: 'a', refreshToken: 'r' };
      },
      refresh: async () => {
        calls.push('refresh');
        return { accessToken: 'a2', refreshToken: 'r2' };
      },
      logout: async () => {
        calls.push('logout');
      }
    } as unknown as AuthService;
    const controller = new AuthController(service);
    const login = Object.assign(new HuaweiLoginDto(), {
      authorizationCode: 'authorization-code',
      deviceKey: 'device-key-1234',
      deviceName: 'WEB-W00'
    });
    const token = Object.assign(new RefreshTokenDto(), { refreshToken: 'refresh-token' });

    await controller.login(login);
    await controller.refresh(token);
    await controller.logout(token);

    expect(calls).toEqual(['login', 'refresh', 'logout']);
  });
});
