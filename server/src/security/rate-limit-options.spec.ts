import { createRateLimitOptions } from './rate-limit-options';

describe('createRateLimitOptions', () => {
  it('sets a finite global request budget and a temporary block', () => {
    expect(createRateLimitOptions()).toEqual([
      {
        name: 'default',
        ttl: 60_000,
        limit: 120,
        blockDuration: 60_000
      }
    ]);
  });
});
