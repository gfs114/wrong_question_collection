import { Context } from '@kit.AbilityKit'
import { AccountSessionState, LoginResult } from '../models/AccountSession'
import { ApiHttpClient } from './ApiHttpClient'
import { AccountSessionService } from './AccountSessionService'

const USER_CANCELED_CODE: number = 1001502012

interface HuaweiLoginBody {
  authorizationCode: string
  deviceKey: string
  deviceName: string
}

export class HuaweiLoginService {
  static isUserCanceled(code: number): boolean {
    return code === USER_CANCELED_CODE
  }

  static async exchange(context: Context, authorizationCode: string,
    deviceName: string): Promise<AccountSessionState> {
    if (authorizationCode.length === 0) {
      throw new Error('Huawei authorization code is empty')
    }
    const deviceKey: string = await AccountSessionService.deviceKey()
    const body: HuaweiLoginBody = {
      authorizationCode: authorizationCode,
      deviceKey: deviceKey,
      deviceName: deviceName
    }
    const result: LoginResult = await ApiHttpClient.post<LoginResult>('/v1/auth/huawei', body)
    return AccountSessionService.installLogin(context, result, deviceName)
  }
}
