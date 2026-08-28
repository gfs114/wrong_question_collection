import {
  Body,
  Controller,
  Get,
  Post,
  Query,
  Req,
  UnauthorizedException,
  UseGuards
} from '@nestjs/common';
import { AccessTokenGuard, AuthenticatedRequest } from '../auth/access-token.guard';
import { SyncPushDto } from './sync.dto';
import { SyncService } from './sync.service';

@Controller('v1/sync')
@UseGuards(AccessTokenGuard)
export class SyncController {
  constructor(private readonly syncService: SyncService) {}

  @Post('push')
  push(@Req() request: AuthenticatedRequest, @Body() input: SyncPushDto) {
    return this.syncService.push(this.userId(request), input.operations);
  }

  @Get('pull')
  pull(
    @Req() request: AuthenticatedRequest,
    @Query('cursor') cursor = '0',
    @Query('limit') limit = '100'
  ) {
    return this.syncService.pull(this.userId(request), cursor, Number(limit));
  }

  private userId(request: AuthenticatedRequest): string {
    if (request.auth === undefined) {
      throw new UnauthorizedException('Authenticated principal is missing');
    }
    return request.auth.userId;
  }
}
