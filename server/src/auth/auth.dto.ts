import { IsString, MaxLength, MinLength } from 'class-validator';

export class HuaweiLoginDto {
  @IsString()
  @MinLength(1)
  @MaxLength(4096)
  authorizationCode!: string;

  @IsString()
  @MinLength(8)
  @MaxLength(128)
  deviceKey!: string;

  @IsString()
  @MinLength(1)
  @MaxLength(128)
  deviceName!: string;
}

export class RefreshTokenDto {
  @IsString()
  @MinLength(20)
  @MaxLength(8192)
  refreshToken!: string;
}
