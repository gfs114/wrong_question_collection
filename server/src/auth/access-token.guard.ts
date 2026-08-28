import {
  CanActivate,
  ExecutionContext,
  Inject,
  Injectable,
  UnauthorizedException
} from '@nestjs/common';
import { DEVICE_SESSION_STORE, DeviceSessionStore } from './auth.contracts';
import { TokenService, VerifiedAccessToken } from './token.service';

export interface AuthenticatedRequest {
  headers: Record<string, string | string[] | undefined>;
  auth?: VerifiedAccessToken;
}

@Injectable()
export class AccessTokenGuard implements CanActivate {
  constructor(
    private readonly tokenService: TokenService,
    @Inject(DEVICE_SESSION_STORE) private readonly sessionStore: DeviceSessionStore
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest<AuthenticatedRequest>();
    const header = request.headers.authorization;
    if (typeof header !== 'string') {
      throw new UnauthorizedException('Bearer access token is required');
    }
    const match = /^Bearer ([^\s]+)$/.exec(header);
    if (match === null) {
      throw new UnauthorizedException('Bearer access token is required');
    }
    const auth = await this.tokenService.verifyAccess(match[1]);
    if (
      !(await this.sessionStore.isDeviceActive(
        auth.userId,
        auth.deviceId,
        auth.sessionGeneration
      ))
    ) {
      throw new UnauthorizedException('The authenticated device is no longer active');
    }
    request.auth = auth;
    return true;
  }
}
