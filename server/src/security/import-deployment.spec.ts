import { readFileSync } from 'node:fs';
import { join } from 'node:path';

function composeText(): string {
  return readFileSync(join(process.cwd(), 'compose.yaml'), 'utf8');
}

function serviceBlock(name: string): string {
  const text = composeText();
  const start = text.indexOf(`  ${name}:`);
  expect(start).toBeGreaterThanOrEqual(0);
  const remainder = text.slice(start + `  ${name}:`.length);
  const nextService = remainder.search(/\n  [a-z][a-z0-9-]*:/);
  return remainder.slice(0, nextService === -1 ? undefined : nextService);
}

describe('OCR worker deployment boundary', () => {
  it('runs the worker with no public ports, a read-only root and dropped capabilities', () => {
    const worker = serviceBlock('ocr-worker');

    expect(worker).not.toMatch(/\n\s+ports:/);
    expect(worker).toMatch(/read_only:\s*true/);
    expect(worker).toMatch(/cap_drop:\s*\["ALL"\]/);
    expect(worker).toMatch(/security_opt:\s*\["no-new-privileges:true"\]/);
    expect(worker).toMatch(/restart:\s*unless-stopped/);
  });

  it('gives the worker only a bounded tmpfs and the shared import volume', () => {
    const worker = serviceBlock('ocr-worker');

    expect(worker).toMatch(/\/tmp:size=256m,noexec,nosuid,nodev/);
    expect(worker).toMatch(/import_data:\/work\/imports/);
    expect(worker).not.toMatch(/mysql_data|backup:/);
  });

  it('shares no Huawei, JWT or backup secrets with the worker', () => {
    const worker = serviceBlock('ocr-worker');

    expect(worker).not.toMatch(/HUAWEI_CLIENT|JWT_ACCESS|JWT_REFRESH|DATA_ENCRYPTION_KEY|MYSQL_ROOT_PASSWORD|DB_BACKUP/);
    expect(worker).toMatch(/DB_HOST/);
    expect(worker).toMatch(/DB_NAME/);
    expect(worker).toMatch(/DB_RUNTIME_USER/);
    expect(worker).toMatch(/DB_RUNTIME_PASSWORD/);
    expect(worker).toMatch(/IMPORT_STORAGE_ROOT:\s*\/work\/imports/);
  });

  it('runs exactly one worker with explicit CPU and memory limits', () => {
    const worker = serviceBlock('ocr-worker');

    expect(worker).toMatch(/replicas:\s*1/);
    expect(worker).toMatch(/cpus:\s*"2\.0"/);
    expect(worker).toMatch(/memory:\s*3072M/);
  });

  it('joins the worker only to the internal worker network shared with MySQL', () => {
    const text = composeText();
    const worker = serviceBlock('ocr-worker');
    const mysql = serviceBlock('mysql');
    const api = serviceBlock('api');

    expect(worker).toMatch(/networks:\s*\n\s+- worker_backend/);
    expect(worker).not.toMatch(/networks:\s*\n\s+- backend/);
    expect(mysql).toMatch(/worker_backend/);
    expect(mysql).toMatch(/backend/);
    expect(api).not.toMatch(/worker_backend/);
    expect(text).toMatch(/worker_backend:\s*\n\s+driver: bridge\n\s+internal: true/);
  });

  it('keeps MySQL unexposed and mounts the import volume into the API', () => {
    const mysql = serviceBlock('mysql');
    const api = serviceBlock('api');

    expect(mysql).not.toMatch(/\n\s+ports:/);
    expect(api).toMatch(/import_data:\/work\/imports/);
    expect(api).toMatch(/IMPORT_STORAGE_ROOT:\s*\/work\/imports/);
  });
});

describe('Caddyfile request body boundary', () => {
  it('caps non-part request bodies at 5 MB', () => {
    const caddyfile = readFileSync(join(process.cwd(), 'Caddyfile'), 'utf8');

    expect(caddyfile).toMatch(/request_body\s*\{[^}]*max_size\s+5MB/s);
  });
});
