import {
  CanActivate,
  ExecutionContext,
  INestApplication,
  UnauthorizedException
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Test } from '@nestjs/testing';
import { createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { Readable } from 'node:stream';
import request = require('supertest');
import { AccessTokenGuard, AuthenticatedRequest } from '../auth/access-token.guard';
import { DEVICE_SESSION_STORE, DeviceSessionStore } from '../auth/auth.contracts';
import { TokenService } from '../auth/token.service';
import { configureHttpApplication } from '../main';
import { importPartParserError, ImportController } from './import.controller';
import { ImportUploadAdmissionService } from './import-upload-admission.service';
import { ImportService } from './import.service';

const JOB_ID = '11111111-1111-4111-8111-111111111111';
const SOURCE_HASH = 'a'.repeat(64);

const tokenService = {
  verifyAccess: jest.fn(async (token: string) => {
    if (token !== 'valid') throw new UnauthorizedException('Invalid access token');
    return {
      userId: 'server-user',
      deviceId: 'server-device',
      sessionGeneration: 'generation-1'
    };
  })
};
const sessionStore = { isDeviceActive: jest.fn().mockResolvedValue(true) };

const admissionProviders = [
  { provide: TokenService, useValue: tokenService },
  { provide: DEVICE_SESSION_STORE, useValue: sessionStore },
  {
    provide: ImportUploadAdmissionService,
    inject: [TokenService, DEVICE_SESSION_STORE],
    useFactory: (tokens: TokenService, sessions: DeviceSessionStore) =>
      new ImportUploadAdmissionService(tokens, sessions)
  }
];

class TestAccessTokenGuard implements CanActivate {
  canActivate(context: ExecutionContext): boolean {
    const incoming = context.switchToHttp().getRequest<AuthenticatedRequest>();
    if (incoming.headers.authorization !== 'Bearer valid') {
      throw new UnauthorizedException('Bearer access token is required');
    }
    incoming.auth = {
      userId: 'server-user',
      deviceId: 'server-device',
      sessionGeneration: 'generation-1'
    };
    return true;
  }
}

function validCreate(): Record<string, unknown> {
  return {
    bankName: 'Algebra mistakes',
    subject: 'Math',
    pageStart: 1,
    pageEnd: 20,
    sourceSize: 8,
    sourceSha256: SOURCE_HASH
  };
}

describe('ImportController', () => {
  let app: INestApplication;
  let service: {
    create: jest.Mock;
    uploadPart: jest.Mock;
    complete: jest.Mock;
    get: jest.Mock;
    cancel: jest.Mock;
    getDraft: jest.Mock;
    confirm: jest.Mock;
    downloadArtifact: jest.Mock;
    ackArtifacts: jest.Mock;
  };

  beforeEach(async () => {
    service = {
      create: jest.fn().mockResolvedValue({ jobId: JOB_ID, status: 'uploading', partCount: 1 }),
      uploadPart: jest.fn().mockResolvedValue(undefined),
      complete: jest.fn().mockResolvedValue({ jobId: JOB_ID, status: 'queued' }),
      get: jest.fn().mockResolvedValue({ jobId: JOB_ID, status: 'uploading' }),
      cancel: jest.fn().mockResolvedValue(undefined),
      getDraft: jest.fn().mockResolvedValue({ jobId: JOB_ID, status: 'review', questions: [] }),
      confirm: jest.fn().mockResolvedValue({ bankId: JOB_ID, questions: [], expiresAt: new Date().toISOString() }),
      downloadArtifact: jest.fn().mockResolvedValue({
        artifactId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        sha256: 'b'.repeat(64),
        size: 4,
        stream: Readable.from(Buffer.from('jpeg')),
        close: jest.fn().mockResolvedValue(undefined)
      }),
      ackArtifacts: jest.fn().mockResolvedValue(undefined)
    };
    const module = await Test.createTestingModule({
      controllers: [ImportController],
      providers: [
        { provide: ImportService, useValue: service },
        {
          provide: ConfigService,
          useValue: { getOrThrow: (key: string) => key === 'IMPORT_PART_BYTES' ? 4_194_304 : undefined }
        },
        ...admissionProviders
      ]
    })
      .overrideGuard(AccessTokenGuard)
      .useClass(TestAccessTokenGuard)
      .compile();
    app = module.createNestApplication();
    configureHttpApplication(app);
    await app.init();
  });

  afterEach(async () => {
    await app.close();
  });

  it.each([
    ['post', '/v1/imports/pdf'],
    ['get', `/v1/imports/pdf/${JOB_ID}`],
    ['delete', `/v1/imports/pdf/${JOB_ID}`],
    ['get', `/v1/imports/pdf/${JOB_ID}/draft`],
    ['post', `/v1/imports/pdf/${JOB_ID}/confirm`],
    ['get', `/v1/imports/pdf/${JOB_ID}/artifacts/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb`],
    ['post', `/v1/imports/pdf/${JOB_ID}/artifacts/ack`]
  ] as const)('requires authentication for %s %s', async (method, path) => {
    const response = await request(app.getHttpServer())[method](path).send(validCreate());
    expect(response.status).toBe(401);
  });

  it('uses only the authenticated user and device when creating a job', async () => {
    const response = await request(app.getHttpServer())
      .post('/v1/imports/pdf')
      .set('Authorization', 'Bearer valid')
      .send(validCreate());

    expect(response.status).toBe(201);
    expect(service.create).toHaveBeenCalledWith(
      'server-user',
      'server-device',
      expect.objectContaining(validCreate())
    );
  });

  it('exposes authenticated draft, confirm, download and exact-set ACK routes', async () => {
    const draft = await request(app.getHttpServer())
      .get(`/v1/imports/pdf/${JOB_ID}/draft`)
      .set('Authorization', 'Bearer valid');
    expect(draft.status).toBe(200);
    expect(service.getDraft).toHaveBeenCalledWith('server-user', JOB_ID);

    const confirmBody = {
      bankName: 'Algebra', subject: 'Math', questions: [{
        draftQuestionId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        type: 'single_choice', question: '1 + 1 = ?',
        options: { A: '1', B: '2' }, answer: 'B', analysis: null, reviewed: true
      }]
    };
    const confirmed = await request(app.getHttpServer())
      .post(`/v1/imports/pdf/${JOB_ID}/confirm`)
      .set('Authorization', 'Bearer valid')
      .send(confirmBody);
    expect(confirmed.status).toBe(201);
    expect(service.confirm).toHaveBeenCalledWith(
      'server-user', 'server-device', JOB_ID, expect.objectContaining(confirmBody)
    );

    const artifactId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const downloaded = await request(app.getHttpServer())
      .get(`/v1/imports/pdf/${JOB_ID}/artifacts/${artifactId}`)
      .set('Authorization', 'Bearer valid');
    expect(downloaded.status).toBe(200);
    expect(downloaded.headers['content-type']).toMatch(/^image\/jpeg/);
    expect(downloaded.headers['content-length']).toBe('4');
    expect(downloaded.headers['x-content-sha256']).toBe('b'.repeat(64));
    expect(downloaded.headers['cache-control']).toBe('no-store');
    expect(service.downloadArtifact).toHaveBeenCalledWith(
      'server-user', 'server-device', JOB_ID, artifactId
    );

    const ack = await request(app.getHttpServer())
      .post(`/v1/imports/pdf/${JOB_ID}/artifacts/ack`)
      .set('Authorization', 'Bearer valid')
      .send({ artifactIds: [artifactId] });
    expect(ack.status).toBe(204);
    expect(service.ackArtifacts).toHaveBeenCalledWith(
      'server-user', 'server-device', JOB_ID, [artifactId]
    );

    const emptyAck = await request(app.getHttpServer())
      .post(`/v1/imports/pdf/${JOB_ID}/artifacts/ack`)
      .set('Authorization', 'Bearer valid')
      .send({ artifactIds: [] });
    expect(emptyAck.status).toBe(204);
    expect(service.ackArtifacts).toHaveBeenLastCalledWith(
      'server-user', 'server-device', JOB_ID, []
    );
  });

  it('accepts uppercase UUID route parameters for confirm, download and ACK', async () => {
    const routeJobId = 'ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF';
    const artifactId = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB';
    const confirm = await request(app.getHttpServer())
      .post(`/v1/imports/pdf/${routeJobId}/confirm`)
      .set('Authorization', 'Bearer valid')
      .send({
        bankName: 'Bank', subject: 'Math', questions: [{
          draftQuestionId: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
          type: 'short_answer', question: 'Question', options: null,
          answer: null, analysis: null, reviewed: true
        }]
      });
    expect(confirm.status).toBe(201);

    const download = await request(app.getHttpServer())
      .get(`/v1/imports/pdf/${routeJobId}/artifacts/${artifactId}`)
      .set('Authorization', 'Bearer valid');
    expect(download.status).toBe(200);

    const ack = await request(app.getHttpServer())
      .post(`/v1/imports/pdf/${routeJobId}/artifacts/ack`)
      .set('Authorization', 'Bearer valid')
      .send({ artifactIds: [artifactId] });
    expect(ack.status).toBe(204);
    expect(service.confirm).toHaveBeenCalledWith(
      'server-user', 'server-device', routeJobId, expect.any(Object)
    );
    expect(service.downloadArtifact).toHaveBeenCalledWith(
      'server-user', 'server-device', routeJobId, artifactId
    );
    expect(service.ackArtifacts).toHaveBeenCalledWith(
      'server-user', 'server-device', routeJobId, [artifactId]
    );
  });

  it('strictly rejects confirmation and ACK identity fields, duplicate IDs and invalid text', async () => {
    const baseQuestion = {
      draftQuestionId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      type: 'single_choice', question: 'Question', options: { A: '1' },
      answer: 'A', analysis: null, reviewed: true
    };
    const badConfirm = await request(app.getHttpServer())
      .post(`/v1/imports/pdf/${JOB_ID}/confirm`)
      .set('Authorization', 'Bearer valid')
      .send({ bankName: 'Bank', subject: 'Math', userId: 'attacker', questions: [baseQuestion] });
    expect(badConfirm.status).toBe(400);
    expect(service.confirm).not.toHaveBeenCalled();

    const duplicateDraft = await request(app.getHttpServer())
      .post(`/v1/imports/pdf/${JOB_ID}/confirm`)
      .set('Authorization', 'Bearer valid')
      .send({ bankName: 'Bank', subject: 'Math', questions: [baseQuestion, baseQuestion] });
    expect(duplicateDraft.status).toBe(400);
    expect(service.confirm).not.toHaveBeenCalled();

    const oversizedOptions = await request(app.getHttpServer())
      .post(`/v1/imports/pdf/${JOB_ID}/confirm`)
      .set('Authorization', 'Bearer valid')
      .send({
        bankName: 'Bank', subject: 'Math', questions: [{
          ...baseQuestion,
          options: Object.fromEntries(Array.from({ length: 11 }, (_, index) => [`A${index}`, 'x']))
        }]
      });
    expect(oversizedOptions.status).toBe(400);
    expect(service.confirm).not.toHaveBeenCalled();

    const duplicateAck = await request(app.getHttpServer())
      .post(`/v1/imports/pdf/${JOB_ID}/artifacts/ack`)
      .set('Authorization', 'Bearer valid')
      .send({ artifactIds: ['bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'] });
    expect(duplicateAck.status).toBe(400);
    expect(service.ackArtifacts).not.toHaveBeenCalled();
  });

  it('requires the options field while accepting an explicit null value', async () => {
    const baseQuestion = {
      draftQuestionId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      type: 'short_answer', question: 'Question',
      answer: null, analysis: null, reviewed: true
    };
    const missing = await request(app.getHttpServer())
      .post(`/v1/imports/pdf/${JOB_ID}/confirm`)
      .set('Authorization', 'Bearer valid')
      .send({ bankName: 'Bank', subject: 'Math', questions: [baseQuestion] });
    expect(missing.status).toBe(400);
    expect(service.confirm).not.toHaveBeenCalled();

    const explicitNull = await request(app.getHttpServer())
      .post(`/v1/imports/pdf/${JOB_ID}/confirm`)
      .set('Authorization', 'Bearer valid')
      .send({
        bankName: 'Bank', subject: 'Math',
        questions: [{ ...baseQuestion, options: null }]
      });
    expect(explicitNull.status).toBe(201);
    expect(service.confirm).toHaveBeenCalledWith(
      'server-user', 'server-device', JOB_ID,
      expect.objectContaining({ questions: [expect.objectContaining({ options: null })] })
    );
  });

  it('keeps JSON parsing and whitelist rejection active on non-part endpoints', async () => {
    const response = await request(app.getHttpServer())
      .post('/v1/imports/pdf')
      .set('Authorization', 'Bearer valid')
      .send({ ...validCreate(), userId: 'attacker', storageKey: 'G:\\secret.pdf' });

    expect(response.status).toBe(400);
    expect(service.create).not.toHaveBeenCalled();
  });

  it.each([
    [{ ...validCreate(), bankName: '' }, 'bankName'],
    [{ ...validCreate(), bankName: 'x'.repeat(256) }, 'bankName'],
    [{ ...validCreate(), subject: '' }, 'subject'],
    [{ ...validCreate(), subject: 'x'.repeat(65) }, 'subject'],
    [{ ...validCreate(), pageStart: 0 }, 'pageStart'],
    [{ ...validCreate(), pageEnd: 21 }, 'pageEnd'],
    [{ ...validCreate(), pageStart: 2, pageEnd: 1 }, 'pageEnd'],
    [{ ...validCreate(), pageStart: 1, pageEnd: 20.5 }, 'pageEnd'],
    [{ ...validCreate(), sourceSize: 0 }, 'sourceSize'],
    [{ ...validCreate(), sourceSha256: 'A'.repeat(64) }, 'sourceSha256'],
    [{ ...validCreate(), sourceSha256: 'a'.repeat(63) }, 'sourceSha256']
  ])('rejects invalid create input mentioning %s', async (body, expectedField) => {
    const response = await request(app.getHttpServer())
      .post('/v1/imports/pdf')
      .set('Authorization', 'Bearer valid')
      .send(body);
    expect(response.status).toBe(400);
    expect(JSON.stringify(response.body)).toContain(expectedField);
  });

  it('rejects a source larger than 200 MB through real DTO validation', async () => {
    const response = await request(app.getHttpServer())
      .post('/v1/imports/pdf')
      .set('Authorization', 'Bearer valid')
      .send({ ...validCreate(), sourceSize: 209_715_201 });
    expect(response.status).toBe(400);
    expect(JSON.stringify(response.body)).toContain('sourceSize');
    expect(service.create).not.toHaveBeenCalled();
  });

  it('accepts only raw application/octet-stream parts and passes the authenticated context', async () => {
    const body = Buffer.from('part');
    const hash = createHash('sha256').update(body).digest('hex');
    const response = await request(app.getHttpServer())
      .put(`/v1/imports/pdf/${JOB_ID}/parts/0`)
      .set('Authorization', 'Bearer valid')
      .set('Content-Type', 'application/octet-stream')
      .set('X-Part-Sha256', hash)
      .send(body);

    expect(response.status).toBe(204);
    expect(response.text).toBe('');
    expect(service.uploadPart).toHaveBeenCalledWith(
      'server-user', 'server-device', JOB_ID, 0, expect.any(Buffer), hash
    );
    expect(service.uploadPart.mock.calls[0][4]).toEqual(body);
  });

  it('returns stable 401 for an invalid token on the raw part route', async () => {
    const response = await request(app.getHttpServer())
      .put(`/v1/imports/pdf/${JOB_ID}/parts/0`)
      .set('Authorization', 'Bearer invalid')
      .set('Content-Type', 'application/octet-stream')
      .set('X-Part-Sha256', 'a'.repeat(64))
      .send(Buffer.from('untrusted-body'));

    expect(response.status).toBe(401);
    expect(service.uploadPart).not.toHaveBeenCalled();
  });

  it('rejects corrupt gzip without exposing a zlib or parser error', async () => {
    const response = await request(app.getHttpServer())
      .put(`/v1/imports/pdf/${JOB_ID}/parts/0`)
      .set('Authorization', 'Bearer valid')
      .set('Content-Type', 'application/octet-stream')
      .set('Content-Encoding', 'gzip')
      .set('X-Part-Sha256', 'a'.repeat(64))
      .send(Buffer.from('not-gzip'));

    expect(response.status).toBe(415);
    expect(response.body.code).toBe('UNSUPPORTED_PART_CONTENT_ENCODING');
    expect(JSON.stringify(response.body)).not.toMatch(/gzip|zlib|incorrect|stack|path/i);
    expect(service.uploadPart).not.toHaveBeenCalled();
  });

  it('maps expected parser failures to a stable safe 400 response', () => {
    const response = {
      status: jest.fn().mockReturnThis(),
      json: jest.fn()
    };
    const next = jest.fn();
    const error = Object.assign(new Error('G:\\private\\incoming incorrect header check'), {
      type: 'entity.parse.failed',
      code: 'Z_DATA_ERROR'
    });

    importPartParserError(error, {}, response, next);

    expect(response.status).toHaveBeenCalledWith(400);
    expect(response.json).toHaveBeenCalledWith({
      statusCode: 400,
      code: 'MALFORMED_PART_BODY',
      message: 'Upload part body is malformed'
    });
    expect(JSON.stringify(response.json.mock.calls)).not.toContain('G:\\private');
    expect(next).not.toHaveBeenCalled();
  });

  it.each([
    ['application/json', Buffer.from('{}')],
    ['text/plain', Buffer.from('part')]
  ])('rejects part content type %s with 415', async (contentType, body) => {
    const response = await request(app.getHttpServer())
      .put(`/v1/imports/pdf/${JOB_ID}/parts/0`)
      .set('Authorization', 'Bearer valid')
      .set('Content-Type', contentType)
      .set('X-Part-Sha256', createHash('sha256').update(body).digest('hex'))
      .send(body);
    expect(response.status).toBe(415);
    expect(response.body.code).toBe('UNSUPPORTED_PART_MEDIA_TYPE');
    expect(service.uploadPart).not.toHaveBeenCalled();
  });

  it.each([undefined, 'A'.repeat(64), 'a'.repeat(63)])(
    'rejects an invalid X-Part-Sha256 header',
    async (hash) => {
      let call = request(app.getHttpServer())
        .put(`/v1/imports/pdf/${JOB_ID}/parts/0`)
        .set('Authorization', 'Bearer valid')
        .set('Content-Type', 'application/octet-stream');
      if (hash !== undefined) call = call.set('X-Part-Sha256', hash);
      const response = await call.send(Buffer.from('part'));
      expect(response.status).toBe(400);
      expect(response.body.code).toBe('INVALID_PART_SHA256');
      expect(service.uploadPart).not.toHaveBeenCalled();
    }
  );

  it('rejects an empty part and an invalid part index with 400', async () => {
    const emptyHash = createHash('sha256').update(Buffer.alloc(0)).digest('hex');
    const empty = await request(app.getHttpServer())
      .put(`/v1/imports/pdf/${JOB_ID}/parts/0`)
      .set('Authorization', 'Bearer valid')
      .set('Content-Type', 'application/octet-stream')
      .set('X-Part-Sha256', emptyHash)
      .send(Buffer.alloc(0));
    const negative = await request(app.getHttpServer())
      .put(`/v1/imports/pdf/${JOB_ID}/parts/-1`)
      .set('Authorization', 'Bearer valid')
      .set('Content-Type', 'application/octet-stream')
      .set('X-Part-Sha256', emptyHash)
      .send(Buffer.from('part'));
    expect(empty.status).toBe(400);
    expect(negative.status).toBe(400);
  });

  it('returns a stable 413 JSON response without paths or stack for a body over 4 MB', async () => {
    const body = Buffer.alloc(4_194_305, 1);
    const response = await request(app.getHttpServer())
      .put(`/v1/imports/pdf/${JOB_ID}/parts/0`)
      .set('Authorization', 'Bearer valid')
      .set('Content-Type', 'application/octet-stream')
      .set('X-Part-Sha256', createHash('sha256').update(body).digest('hex'))
      .send(body);

    expect(response.status).toBe(413);
    expect(response.body).toEqual({
      statusCode: 413,
      code: 'PART_TOO_LARGE',
      message: 'Upload part exceeds the configured limit'
    });
    expect(JSON.stringify(response.body)).not.toMatch(/stack|path|G:\\/i);
    expect(service.uploadPart).not.toHaveBeenCalled();
  });

  it('honors the minimum configured part limit in the route-specific raw parser', async () => {
    const module = await Test.createTestingModule({
      controllers: [ImportController],
      providers: [
        { provide: ImportService, useValue: service },
        {
          provide: ConfigService,
          useValue: { getOrThrow: (key: string) => key === 'IMPORT_PART_BYTES' ? 65_536 : undefined }
        },
        ...admissionProviders
      ]
    })
      .overrideGuard(AccessTokenGuard)
      .useClass(TestAccessTokenGuard)
      .compile();
    const limitedApp = module.createNestApplication();
    configureHttpApplication(limitedApp);
    await limitedApp.init();
    try {
      const body = Buffer.alloc(65_537, 1);
      const response = await request(limitedApp.getHttpServer())
        .put(`/v1/imports/pdf/${JOB_ID}/parts/0`)
        .set('Authorization', 'Bearer valid')
        .set('Content-Type', 'application/octet-stream')
        .set('X-Part-Sha256', createHash('sha256').update(body).digest('hex'))
        .send(body);
      expect(response.status).toBe(413);
      expect(response.body.code).toBe('PART_TOO_LARGE');
      expect(service.uploadPart).not.toHaveBeenCalled();
    } finally {
      await limitedApp.close();
    }
  });

  it('validates complete DTO and binds completion to the authenticated device', async () => {
    const valid = await request(app.getHttpServer())
      .post(`/v1/imports/pdf/${JOB_ID}/complete`)
      .set('Authorization', 'Bearer valid')
      .send({ partCount: 1, sourceSha256: SOURCE_HASH });
    expect(valid.status).toBe(202);
    expect(service.complete).toHaveBeenCalledWith(
      'server-user', 'server-device', JOB_ID,
      { partCount: 1, sourceSha256: SOURCE_HASH },
      expect.any(AbortSignal)
    );

    const invalid = await request(app.getHttpServer())
      .post(`/v1/imports/pdf/${JOB_ID}/complete`)
      .set('Authorization', 'Bearer valid')
      .send({ partCount: 0, sourceSha256: SOURCE_HASH, userId: 'attacker' });
    expect(invalid.status).toBe(400);
  });

  it('rejects a complete request above the absolute part-count limit', async () => {
    const response = await request(app.getHttpServer())
      .post(`/v1/imports/pdf/${JOB_ID}/complete`)
      .set('Authorization', 'Bearer valid')
      .send({ partCount: 3_201, sourceSha256: SOURCE_HASH });

    expect(response.status).toBe(400);
    expect(JSON.stringify(response.body)).toContain('partCount');
    expect(service.complete).not.toHaveBeenCalled();
  });

  it('binds status to user and cancellation to user plus device', async () => {
    const status = await request(app.getHttpServer())
      .get(`/v1/imports/pdf/${JOB_ID}`)
      .set('Authorization', 'Bearer valid');
    const cancelled = await request(app.getHttpServer())
      .delete(`/v1/imports/pdf/${JOB_ID}`)
      .set('Authorization', 'Bearer valid');

    expect(status.status).toBe(200);
    expect(status.body).toEqual({ jobId: JOB_ID, status: 'uploading' });
    expect(service.get).toHaveBeenCalledWith('server-user', JOB_ID);
    expect(cancelled.status).toBe(204);
    expect(service.cancel).toHaveBeenCalledWith(
      'server-user', 'server-device', JOB_ID, expect.any(AbortSignal)
    );
  });

  it('aborts an in-flight service wait when the client response closes', async () => {
    const controller = new ImportController(service as unknown as ImportService);
    const incoming = Object.assign(new EventEmitter(), {
      headers: { authorization: 'Bearer valid' },
      auth: {
        userId: 'server-user',
        deviceId: 'server-device',
        sessionGeneration: 'generation-1'
      },
      res: new EventEmitter()
    });
    let observedSignal: AbortSignal | undefined;
    service.complete.mockImplementationOnce(async (
      _userId: string,
      _deviceId: string,
      _jobId: string,
      _input: unknown,
      signal: AbortSignal
    ) => {
      observedSignal = signal;
      await new Promise<void>((_resolve, reject) => {
        signal.addEventListener('abort', () => reject(new Error('request closed')), { once: true });
      });
    });

    const pending = controller.complete(
      incoming,
      { jobId: JOB_ID },
      { partCount: 1, sourceSha256: SOURCE_HASH }
    );
    incoming.res.emit('close');

    await expect(pending).rejects.toThrow('request closed');
    expect(observedSignal?.aborted).toBe(true);
  });
});
