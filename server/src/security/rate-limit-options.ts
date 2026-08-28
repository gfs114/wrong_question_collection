import { ThrottlerModuleOptions } from '@nestjs/throttler';

export function createRateLimitOptions(): ThrottlerModuleOptions {
  return [
    {
      name: 'default',
      ttl: 60_000,
      limit: 120,
      blockDuration: 60_000
    }
  ];
}
