import { readFileSync } from 'node:fs';
import { join } from 'node:path';

describe('Caddyfile', () => {
  it('uses a catch-all HTTPS site so raw IP clients without SNI receive the certificate', () => {
    const caddyfile = readFileSync(join(process.cwd(), 'Caddyfile'), 'utf8');

    expect(caddyfile).toMatch(/^https:\/\/\s*\{/);
    expect(caddyfile).not.toContain('https://{$SERVER_IP}');
  });
});
