export interface SessionTokens {
  accessToken: string
  refreshToken: string
  expiresInSeconds: number
}

export interface LoginResult extends SessionTokens {
  userId: string
  deviceId: string
}

export interface AccountSessionState {
  signedIn: boolean
  userId: string
  deviceName: string
}

export class AccountSessionTiming {
  static expiresAt(now: number, expiresInSeconds: number): number {
    const safeSeconds: number = Math.max(0, expiresInSeconds)
    return now + safeSeconds * 1000
  }

  static isFresh(expiresAt: number, now: number, safetyWindowMs: number = 30000): boolean {
    return expiresAt > now + Math.max(0, safetyWindowMs)
  }
}
