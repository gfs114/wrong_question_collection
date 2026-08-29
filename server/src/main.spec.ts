import {
  CanActivate,
  ExecutionContext,
  INestApplication,
  UnauthorizedException
} from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { Test } from '@nestjs/testing';
import { getDataSourceToken } from '@nestjs/typeorm';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import request = require('supertest');
import { AccessTokenGuard, AuthenticatedRequest } from './auth/access-token.guard';
import { DEVICE_SESSION_STORE } from './auth/auth.contracts';
import { TokenService } from './auth/token.service';
import { ImportUploadAdmissionService } from './imports/import-upload-admission.service';
import { ImportService } from './imports/import.service';

interface ProductionMainModule {
  bootstrap?: () => Promise<void>;
  configureHttpApplication?: (app: INestApplication) => void;
}

class TestAccessTokenGuard implements CanActivate {
  canActivate(context: ExecutionContext): boolean {
    const incoming = context.switchToHttp().getRequest<AuthenticatedRequest>();
    if (incoming.headers.authorization !== 'Bearer valid') {
      throw new UnauthorizedException('Bearer access token is required');
    }
    incoming.auth = {
      userId: 'production-user',
      deviceId: 'production-device',
      sessionGeneration: 'generation-1'
    };
    return true;
  }
}

function installTestEnvironment(): Record<string, string | undefined> {
  const values: Record<string, string> = {
    NODE_ENV: 'test',
    PORT: '3000',
    DB_HOST: '127.0.0.1',
    DB_PORT: '3306',
    DB_NAME: 'wrong_question_test',
    DB_USER: 'test_user',
    DB_PASSWORD: 'd'.repeat(32),
    DB_RUN_MIGRATIONS: 'false',
    JWT_ACCESS_SECRET: 'a'.repeat(32),
    JWT_REFRESH_SECRET: 'b'.repeat(32),
    DATA_ENCRYPTION_KEY: 'c'.repeat(64),
    HUAWEI_CLIENT_ID: 'test-client',
    HUAWEI_CLIENT_SECRET: 'test-secret',
    HUAWEI_TOKEN_URL: 'https://example.test/token',
    HUAWEI_PROFILE_URL: 'https://example.test/profile',
    IMPORT_STORAGE_ROOT: resolve(process.cwd(), '.test-import-storage'),
    IMPORT_MAX_PDF_BYTES: '209715200',
    IMPORT_PART_BYTES: '4194304',
    IMPORT_ARTIFACT_TTL_HOURS: '24',
    IMPORT_MIN_FREE_BYTES: '1'
  };
  const previous: Record<string, string | undefined> = {};
  for (const [key, value] of Object.entries(values)) {
    previous[key] = process.env[key];
    process.env[key] = value;
  }
  return previous;
}

function restoreEnvironment(previous: Record<string, string | undefined>): void {
  for (const [key, value] of Object.entries(previous)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
}

describe('production bootstrap', () => {
  it('creates AppModule, applies the production HTTP configuration, and listens on the configured port', async () => {
    const previousEnvironment = installTestEnvironment();
    const httpServer = { set: jest.fn() };
    const config = {
      getOrThrow: jest.fn((key: string) => key === 'PORT' ? 3000 : 4_194_304)
    };
    const admission = { middleware: jest.fn().mockReturnValue(jest.fn()) };
    const app = {
      getHttpAdapter: jest.fn().mockReturnValue({
        getInstance: jest.fn().mockReturnValue(httpServer)
      }),
      get: jest.fn((token: unknown) => token === ImportUploadAdmissionService ? admission : config),
      use: jest.fn(),
      useGlobalPipes: jest.fn(),
      enableShutdownHooks: jest.fn(),
      listen: jest.fn().mockResolvedValue(undefined)
    };
    const create = jest.spyOn(NestFactory, 'create').mockResolvedValue(app as never);

    try {
      const production = require('./main') as ProductionMainModule;
      const { AppModule } = require('./app.module') as typeof import('./app.module');
      expect(create).not.toHaveBeenCalled();
      expect(typeof production.bootstrap).toBe('function');

      await production.bootstrap?.();

      expect(create).toHaveBeenCalledWith(AppModule, { bufferLogs: true, bodyParser: false });
      expect(httpServer.set).toHaveBeenCalledWith('trust proxy', 1);
      expect(app.use).toHaveBeenCalledWith(
        '/v1/imports/pdf/:jobId/parts/:partIndex',
        expect.any(Function),
        expect.any(Function),
        expect.any(Function)
      );
      expect(app.use).toHaveBeenCalledWith(
        '/v1/imports/pdf/:jobId/confirm',
        expect.any(Function),
        expect.any(Function),
        expect.any(Function)
      );
      expect(app.use).toHaveBeenCalledWith(expect.any(Function));
      expect(app.useGlobalPipes).toHaveBeenCalledTimes(1);
      expect(app.enableShutdownHooks).toHaveBeenCalledTimes(1);
      expect(app.listen).toHaveBeenCalledWith(3000, '0.0.0.0');
    } finally {
      create.mockRestore();
      restoreEnvironment(previousEnvironment);
    }
  });

  it('fails startup before listen when the configured part size is below 64 KiB', async () => {
    const previousEnvironment = installTestEnvironment();
    const config = {
      getOrThrow: jest.fn((key: string) => key === 'PORT' ? 3000 : 1)
    };
    const admission = { middleware: jest.fn().mockReturnValue(jest.fn()) };
    const app = {
      getHttpAdapter: jest.fn().mockReturnValue({
        getInstance: jest.fn().mockReturnValue({ set: jest.fn() })
      }),
      get: jest.fn((token: unknown) => token === ImportUploadAdmissionService ? admission : config),
      use: jest.fn(),
      useGlobalPipes: jest.fn(),
      enableShutdownHooks: jest.fn(),
      listen: jest.fn().mockResolvedValue(undefined)
    };
    const create = jest.spyOn(NestFactory, 'create').mockResolvedValue(app as never);

    try {
      const production = require('./main') as ProductionMainModule;
      await expect(production.bootstrap?.()).rejects.toThrow(
        'IMPORT_PART_BYTES must be an integer between 65536 and 4194304'
      );
      expect(app.listen).not.toHaveBeenCalled();
    } finally {
      create.mockRestore();
      restoreEnvironment(previousEnvironment);
    }
  });
});

describe('production HTTP application wiring', () => {
  let app: INestApplication | undefined;
  let previousEnvironment: Record<string, string | undefined>;
  let imports: {
    create: jest.Mock;
    uploadPart: jest.Mock;
    complete: jest.Mock;
    get: jest.Mock;
    cancel: jest.Mock;
  };

  beforeAll(async () => {
    previousEnvironment = installTestEnvironment();
    const production = require('./main') as ProductionMainModule;
    expect(typeof production.configureHttpApplication).toBe('function');
    const { AppModule } = require('./app.module') as typeof import('./app.module');
    imports = {
      create: jest.fn().mockResolvedValue({ jobId: '11111111-1111-4111-8111-111111111111', status: 'uploading', partCount: 1 }),
      uploadPart: jest.fn().mockResolvedValue(undefined),
      complete: jest.fn().mockResolvedValue({ jobId: '11111111-1111-4111-8111-111111111111', status: 'queued' }),
      get: jest.fn().mockResolvedValue({ jobId: '11111111-1111-4111-8111-111111111111', status: 'uploading' }),
      cancel: jest.fn().mockResolvedValue(undefined)
    };
    const dataSource = {
      getRepository: jest.fn().mockReturnValue({}),
      entityMetadatas: [],
      options: { type: 'mysql' },
      manager: {},
      isInitialized: true,
      destroy: jest.fn().mockResolvedValue(undefined)
    };
    const module = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(getDataSourceToken())
      .useValue(dataSource)
      .overrideProvider(ImportService)
      .useValue(imports)
      .overrideProvider(TokenService)
      .useValue({
        verifyAccess: jest.fn(async (token: string) => {
          if (token !== 'valid') throw new UnauthorizedException('Invalid access token');
          return {
            userId: 'production-user',
            deviceId: 'production-device',
            sessionGeneration: 'generation-1'
          };
        })
      })
      .overrideProvider(DEVICE_SESSION_STORE)
      .useValue({ isDeviceActive: jest.fn().mockResolvedValue(true) })
      .overrideGuard(AccessTokenGuard)
      .useClass(TestAccessTokenGuard)
      .compile();
    app = module.createNestApplication();
    production.configureHttpApplication?.(app);
    await app.init();
  });

  afterAll(async () => {
    if (app !== undefined) await app.close();
    restoreEnvironment(previousEnvironment);
  });

  it('boots AppModule with the imports route and production JSON validation', async () => {
    const valid = {
      bankName: 'Bank',
      subject: 'Math',
      pageStart: 1,
      pageEnd: 1,
      sourceSize: 4,
      sourceSha256: 'a'.repeat(64)
    };
    const created = await request(app?.getHttpServer())
      .post('/v1/imports/pdf')
      .set('Authorization', 'Bearer valid')
      .send(valid);
    const rejected = await request(app?.getHttpServer())
      .post('/v1/imports/pdf')
      .set('Authorization', 'Bearer valid')
      .send({ ...valid, userId: 'attacker' });

    expect(created.status).toBe(201);
    expect(rejected.status).toBe(400);
    expect(imports.create).toHaveBeenCalledTimes(1);
  });

  it('uses production raw parsing only for octet-stream parts with the production limit', async () => {
    const jobId = '11111111-1111-4111-8111-111111111111';
    const body = Buffer.from('part');
    const hash = createHash('sha256').update(body).digest('hex');
    const accepted = await request(app?.getHttpServer())
      .put(`/v1/imports/pdf/${jobId}/parts/0`)
      .set('Authorization', 'Bearer valid')
      .set('Content-Type', 'application/octet-stream')
      .set('X-Part-Sha256', hash)
      .send(body);
    const unsupported = await request(app?.getHttpServer())
      .put(`/v1/imports/pdf/${jobId}/parts/0`)
      .set('Authorization', 'Bearer valid')
      .set('Content-Type', 'text/plain')
      .set('X-Part-Sha256', hash)
      .send(body);
    const oversizedBody = Buffer.alloc(4_194_305, 1);
    const oversized = await request(app?.getHttpServer())
      .put(`/v1/imports/pdf/${jobId}/parts/0`)
      .set('Authorization', 'Bearer valid')
      .set('Content-Type', 'application/octet-stream')
      .set('X-Part-Sha256', createHash('sha256').update(oversizedBody).digest('hex'))
      .send(oversizedBody);

    expect(accepted.status).toBe(204);
    expect(imports.uploadPart).toHaveBeenCalledWith(
      'production-user', 'production-device', jobId, 0, expect.any(Buffer), hash
    );
    expect(imports.uploadPart.mock.calls[0][4]).toEqual(body);
    expect(unsupported.status).toBe(415);
    expect(oversized.status).toBe(413);
    expect(oversized.body.code).toBe('PART_TOO_LARGE');
  });
});
