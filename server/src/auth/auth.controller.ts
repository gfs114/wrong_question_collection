import { Body, Controller, HttpCode, Post } from '@nestjs/common';
import { AuthService, LoginResult } from './auth.service';
import { HuaweiLoginDto, RefreshTokenDto } from './auth.dto';
import { SessionTokens } from './token.service';

@Controller('v1/auth')
export class AuthController {
  constructor(private readonly authService: AuthService) {}

  @Post('huawei')
  login(@Body() input: HuaweiLoginDto): Promise<LoginResult> {
    return this.authService.loginWithHuawei(input);
  }

  @Post('refresh')
  refresh(@Body() input: RefreshTokenDto): Promise<SessionTokens> {
    return this.authService.refresh(input.refreshToken);
  }

  @Post('logout')
  @HttpCode(204)
  logout(@Body() input: RefreshTokenDto): Promise<void> {
    return this.authService.logout(input.refreshToken);
  }
}
