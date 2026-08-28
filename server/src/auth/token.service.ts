import { Inject, Injectable, UnauthorizedException } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { createHash, randomUUID } from 'node:crypto';

export const JWT_ACCESS_SECRET = Symbol('JWT_ACCESS_SECRET');
export const JWT_REFRESH_SECRET = Symbol('JWT_REFRESH_SECRET');

export interface SessionTokens {
  accessToken: string;
  refreshToken: string;
  expiresInSeconds: number;
}

export interface VerifiedRefreshToken {
  userId: string;
  deviceId: string;
  sessionGeneration: string;
}

export type VerifiedAccessToken = VerifiedRefreshToken;

interface TokenPayload {
  sub: string;
  deviceId: string;
  sessionGeneration: string;
  tokenType: 'access' | 'refresh';
  jti: string;
}

@Injectable()
export class TokenService {
  private readonly accessLifetimeSeconds = 15 * 60;
  private readonly refreshLifetimeSeconds = 30 * 24 * 60 * 60;

  constructor(
    private readonly jwtService: JwtService,
    @Inject(JWT_ACCESS_SECRET) private readonly accessSecret: string,
    @Inject(JWT_REFRESH_SECRET) private readonly refreshSecret: string
  ) {}

  async issue(
    userId: string,
    deviceId: string,
    sessionGeneration: string
  ): Promise<SessionTokens> {
    const accessPayload: TokenPayload = {
      sub: userId,
      deviceId,
      sessionGeneration,
      tokenType: 'access',
      jti: randomUUID()
    };
    const refreshPayload: TokenPayload = {
      sub: userId,
      deviceId,
      sessionGeneration,
      tokenType: 'refresh',
      jti: randomUUID()
    };
    const [accessToken, refreshToken] = await Promise.all([
      this.jwtService.signAsync(accessPayload, {
        secret: this.accessSecret,
        expiresIn: this.accessLifetimeSeconds
      }),
      this.jwtService.signAsync(refreshPayload, {
        secret: this.refreshSecret,
        expiresIn: this.refreshLifetimeSeconds
      })
    ]);
    return {
      accessToken,
      refreshToken,
      expiresInSeconds: this.accessLifetimeSeconds
    };
  }

  async verifyRefresh(token: string): Promise<VerifiedRefreshToken> {
    try {
      const payload = await this.jwtService.verifyAsync<TokenPayload>(token, {
        secret: this.refreshSecret
      });
      if (
        payload.tokenType !== 'refresh' ||
        !payload.sub ||
        !payload.deviceId ||
        !payload.sessionGeneration
      ) {
        throw new UnauthorizedException('Invalid refresh token');
      }
      return {
        userId: payload.sub,
        deviceId: payload.deviceId,
        sessionGeneration: payload.sessionGeneration
      };
    } catch {
      throw new UnauthorizedException('Invalid refresh token');
    }
  }

  async verifyAccess(token: string): Promise<VerifiedAccessToken> {
    try {
      const payload = await this.jwtService.verifyAsync<TokenPayload>(token, {
        secret: this.accessSecret
      });
      if (
        payload.tokenType !== 'access' ||
        !payload.sub ||
        !payload.deviceId ||
        !payload.sessionGeneration
      ) {
        throw new UnauthorizedException('Invalid access token');
      }
      return {
        userId: payload.sub,
        deviceId: payload.deviceId,
        sessionGeneration: payload.sessionGeneration
      };
    } catch {
      throw new UnauthorizedException('Invalid access token');
    }
  }

  hashRefreshToken(token: string): string {
    return createHash('sha256').update(token, 'utf8').digest('hex');
  }
}
