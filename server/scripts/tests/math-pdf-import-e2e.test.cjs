'use strict';

const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { mkdtemp, readFile, rm, writeFile } = require('node:fs/promises');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { afterEach, beforeEach, test } = require('node:test');

const {
  ApiClient,
  RunnerError,
  readFully,
  runImport,
} = require('../math-pdf-import-e2e.cjs');

const JOB_ID = '11111111-1111-4111-8111-111111111111';
const DRAFT = {
  jobId: JOB_ID,
  status: 'review',
  bankName: 'Math PDF E2E',
  subject: 'Math',
  expiresAt: '2099-09-04T00:00:00.000Z',
  questions: [{
    draftQuestionId: '22222222-2222-4222-8222-222222222222',
    type: 'short_answer',
    question: String.raw`例1.6 证明 $f(x)=\frac{x}{1+x^2}$ 在 $(-\infty,+\infty)$ 内有界。`,
    options: null,
    answer: null,
    analysis: null,
    pageStart: 2,
    pageEnd: 2,
    confidence: 0.91,
    reviewRequired: true,
    images: [],
  }],
};

let server;
let baseUrl;
let events;
let pollCount;
let terminalStatus;
let draftPayload;
let uploadFailure;
let trickleResponse;
let temporaryDirectories;

function sendJson(response, status, payload) {
  const body = Buffer.from(JSON.stringify(payload), 'utf8');
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': body.length,
  });
  response.end(body);
}

async function readBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return Buffer.concat(chunks);
}

beforeEach(async () => {
  events = [];
  pollCount = 0;
  terminalStatus = 'review';
  draftPayload = structuredClone(DRAFT);
  uploadFailure = false;
  trickleResponse = false;
  temporaryDirectories = [];
  server = http.createServer(async (request, response) => {
    if (request.headers.authorization !== 'Bearer secret-token') {
      sendJson(response, 401, { code: 'UNAUTHORIZED' });
      return;
    }
    const body = await readBody(request);
    const eventBody = request.headers['content-type'] === 'application/json'
      ? JSON.parse(body.toString('utf8'))
      : body;
    events.push({ method: request.method, path: request.url, body: eventBody, headers: request.headers });

    if (request.method === 'GET' && request.url === '/trickle') {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.write('{');
      const interval = setInterval(() => response.write(' '), 10);
      const finish = setTimeout(() => {
        clearInterval(interval);
        response.end('}');
      }, 150);
      response.on('close', () => {
        clearInterval(interval);
        clearTimeout(finish);
      });
      return;
    }

    if (request.method === 'POST' && request.url === '/v1/imports/pdf') {
      sendJson(response, 201, { jobId: JOB_ID, status: 'uploading', partCount: 2 });
      return;
    }
    if (request.method === 'PUT' && request.url.startsWith(`/v1/imports/pdf/${JOB_ID}/parts/`)) {
      if (uploadFailure) {
        const message = uploadFailure === 'echo-token'
          ? 'proxy echoed Bearer secret-token'
          : 'simulated upload failure';
        sendJson(response, 500, { code: 'UPLOAD_FAILED', message });
        return;
      }
      response.writeHead(204, { 'content-length': 0 });
      response.end();
      return;
    }
    if (request.method === 'POST' && request.url === `/v1/imports/pdf/${JOB_ID}/complete`) {
      sendJson(response, 202, { jobId: JOB_ID, status: 'queued' });
      return;
    }
    if (request.method === 'GET' && request.url === `/v1/imports/pdf/${JOB_ID}/draft`) {
      sendJson(response, 200, draftPayload);
      return;
    }
    if (request.method === 'GET' && request.url === `/v1/imports/pdf/${JOB_ID}`) {
      pollCount += 1;
      const status = terminalStatus === 'failed'
        ? 'failed'
        : (pollCount === 1 ? 'processing' : 'review');
      sendJson(response, 200, {
        jobId: JOB_ID,
        status,
        progress: { current: Math.min(pollCount, 2), total: 2 },
      });
      return;
    }
    sendJson(response, 404, { code: 'NOT_FOUND' });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

afterEach(async () => {
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  await Promise.all(temporaryDirectories.map((directory) => rm(directory, { recursive: true, force: true })));
});

async function fixture() {
  const root = await mkdtemp(path.join(os.tmpdir(), 'wqc-math-pdf-'));
  temporaryDirectories.push(root);
  const pdfPath = path.join(root, 'math.pdf');
  const pdfBytes = Buffer.concat([Buffer.from('%PDF-1.7\n'), Buffer.from(Array.from({ length: 32 }, (_, i) => i))]);
  await writeFile(pdfPath, pdfBytes);
  return {
    root,
    pdfPath,
    pdfBytes,
    outputPath: path.join(root, 'before-fix-draft.json'),
    summaryPath: path.join(root, 'before-fix-run.json'),
  };
}

function config(files) {
  return {
    pdfPath: files.pdfPath,
    outputPath: files.outputPath,
    summaryPath: files.summaryPath,
    bankName: 'Math PDF E2E',
    subject: 'Math',
    pageStart: 1,
    pageEnd: 2,
    pollIntervalSeconds: 0,
    timeoutSeconds: 30,
    expectedCount: 1,
    expectedLabels: ['例1.6'],
    expectedQuestionContains: [],
    rejectedQuestionContains: [],
    expectedQuestionOrder: [],
  };
}

test('runs the existing import flow and preserves LaTeX in the raw draft', async () => {
  const files = await fixture();
  const result = await runImport(
    config(files),
    new ApiClient(baseUrl, 'secret-token', { requestTimeoutSeconds: 5 }),
    { sleep: async () => {} },
  );

  assert.deepEqual(result.draft, DRAFT);
  assert.deepEqual(JSON.parse(await readFile(files.outputPath, 'utf8')), DRAFT);
  assert.match(await readFile(files.outputPath, 'utf8'), /\\\\frac/);
  assert.equal(JSON.parse(await readFile(files.summaryPath, 'utf8')).jobId, JOB_ID);
  assert.equal(result.summary.questionCount, 1);

  assert.deepEqual(events.map(({ method, path: requestPath }) => [method, requestPath]), [
    ['POST', '/v1/imports/pdf'],
    ['PUT', `/v1/imports/pdf/${JOB_ID}/parts/0`],
    ['PUT', `/v1/imports/pdf/${JOB_ID}/parts/1`],
    ['POST', `/v1/imports/pdf/${JOB_ID}/complete`],
    ['GET', `/v1/imports/pdf/${JOB_ID}`],
    ['GET', `/v1/imports/pdf/${JOB_ID}`],
    ['GET', `/v1/imports/pdf/${JOB_ID}/draft`],
  ]);
  const uploaded = Buffer.concat(events.filter((event) => event.method === 'PUT').map((event) => event.body));
  assert.deepEqual(uploaded, files.pdfBytes);
  for (const event of events.filter((candidate) => candidate.method === 'PUT')) {
    assert.equal(event.headers['content-type'], 'application/octet-stream');
    assert.equal(event.headers['x-part-sha256'], createHash('sha256').update(event.body).digest('hex'));
  }
  assert.equal(events[0].body.sourceSha256, createHash('sha256').update(files.pdfBytes).digest('hex'));
  assert.equal(events[0].body.sourceSize, files.pdfBytes.length);
});

test('stops on a terminal failed job without fetching a draft', async () => {
  terminalStatus = 'failed';
  const files = await fixture();

  await assert.rejects(
    runImport(
      { ...config(files), expectedCount: undefined, expectedLabels: [] },
      new ApiClient(baseUrl, 'secret-token', { requestTimeoutSeconds: 5 }),
      { sleep: async () => {} },
    ),
    (error) => error instanceof RunnerError && /failed/.test(error.message),
  );

  assert.equal(events.some((event) => event.path.endsWith('/draft')), false);
  assert.equal(JSON.parse(await readFile(files.summaryPath, 'utf8')).finalStatus, 'failed');
});

test('rejects cleartext HTTP for non-loopback servers unless explicitly allowed', () => {
  assert.throws(
    () => new ApiClient('http://192.0.2.10', 'secret-token'),
    (error) => error instanceof RunnerError && /cleartext HTTP/.test(error.message),
  );
  assert.doesNotThrow(() => new ApiClient(
    'http://192.0.2.10',
    'secret-token',
    { allowHttp: true },
  ));
});

test('caps polling sleep at the remaining deadline and times out before another request', async () => {
  const files = await fixture();
  let clock = 0;
  const sleeps = [];

  await assert.rejects(
    runImport(
      {
        ...config(files),
        expectedCount: undefined,
        expectedLabels: [],
        pollIntervalSeconds: 10,
        timeoutSeconds: 5,
      },
      new ApiClient(baseUrl, 'secret-token', { requestTimeoutSeconds: 30 }),
      {
        monotonic: () => clock,
        sleep: async (milliseconds) => {
          sleeps.push(milliseconds);
          clock += milliseconds / 1000;
        },
      },
    ),
    (error) => error instanceof RunnerError && /timed out/.test(error.message),
  );

  assert.deepEqual(sleeps, [5000]);
  assert.equal(events.filter((event) => event.method === 'GET').length, 1);
  assert.equal(JSON.parse(await readFile(files.summaryPath, 'utf8')).finalStatus, 'timeout');
});

test('does not accept 例1.10 as the expected 例1.1 label', async () => {
  draftPayload.questions[0].question = '例1.10 求函数定义域。';
  const files = await fixture();

  await assert.rejects(
    runImport(
      { ...config(files), expectedLabels: ['例1.1'] },
      new ApiClient(baseUrl, 'secret-token', { requestTimeoutSeconds: 5 }),
      { sleep: async () => {} },
    ),
    (error) => error instanceof RunnerError && /missing expected label: 例1\.1/.test(error.message),
  );

  assert.equal(JSON.parse(await readFile(files.summaryPath, 'utf8')).validationErrors.length, 1);
  assert.equal(JSON.parse(await readFile(files.outputPath, 'utf8')).questions[0].question, '例1.10 求函数定义域。');
});

test('supports scoped per-question required and rejected content assertions', async () => {
  const files = await fixture();
  const result = await runImport(
    {
      ...config(files),
      expectedQuestionContains: [String.raw`例1.6::\frac{x}{1+x^2}`],
      rejectedQuestionContains: ['例1.6::f ( ) $'],
    },
    new ApiClient(baseUrl, 'secret-token', { requestTimeoutSeconds: 5 }),
    { sleep: async () => {} },
  );

  assert.deepEqual(result.summary.validationErrors, []);
});

test('reports scoped content assertion failures after saving the draft', async () => {
  const files = await fixture();

  await assert.rejects(
    runImport(
      {
        ...config(files),
        expectedQuestionContains: ['例1.6::missing fragment'],
        rejectedQuestionContains: [String.raw`例1.6::\frac{x}{1+x^2}`],
      },
      new ApiClient(baseUrl, 'secret-token', { requestTimeoutSeconds: 5 }),
      { sleep: async () => {} },
    ),
    (error) => error instanceof RunnerError
      && /missing expected content/.test(error.message)
      && /rejected content/.test(error.message),
  );

  const summary = JSON.parse(await readFile(files.summaryPath, 'utf8'));
  assert.equal(summary.validationErrors.length, 2);
  assert.deepEqual(JSON.parse(await readFile(files.outputPath, 'utf8')), DRAFT);
});

test('supports scoped ordering assertions for formula placement', async () => {
  const files = await fixture();
  const result = await runImport(
    {
      ...config(files),
      expectedQuestionOrder: [String.raw`例1.6::\frac{x}{1+x^2}::在`],
    },
    new ApiClient(baseUrl, 'secret-token', { requestTimeoutSeconds: 5 }),
    { sleep: async () => {} },
  );

  assert.deepEqual(result.summary.validationErrors, []);
});

test('rejects malformed scoped assertions before creating an import job', async () => {
  const files = await fixture();

  await assert.rejects(
    runImport(
      { ...config(files), expectedQuestionContains: ['例1.6'] },
      new ApiClient(baseUrl, 'secret-token', { requestTimeoutSeconds: 5 }),
    ),
    (error) => error instanceof RunnerError && /LABEL::TEXT/.test(error.message),
  );
  assert.equal(events.length, 0);
});

test('persists a sanitized run summary when upload fails after job creation', async () => {
  uploadFailure = 'echo-token';
  const files = await fixture();

  await assert.rejects(
    runImport(
      { ...config(files), expectedCount: undefined, expectedLabels: [] },
      new ApiClient(baseUrl, 'secret-token', { requestTimeoutSeconds: 5 }),
      { sleep: async () => {} },
    ),
    (error) => error instanceof RunnerError
      && /UPLOAD_FAILED/.test(error.message)
      && !/secret-token/.test(error.message)
      && /\[REDACTED\]/.test(error.message),
  );

  const summaryText = await readFile(files.summaryPath, 'utf8');
  const summary = JSON.parse(summaryText);
  assert.equal(summary.finalStatus, 'error');
  assert.equal(summary.failedStage, 'upload');
  assert.match(summary.failureMessage, /UPLOAD_FAILED/);
  assert.doesNotMatch(summaryText, /secret-token/);
  assert.match(summary.failureMessage, /\[REDACTED\]/);
});

test('enforces a wall-clock request deadline while the server trickles bytes', async () => {
  trickleResponse = true;
  const started = Date.now();

  await assert.rejects(
    new ApiClient(baseUrl, 'secret-token', { requestTimeoutSeconds: 1 }).request(
      'GET',
      '/trickle',
      { timeoutSeconds: 0.05 },
    ),
    (error) => error instanceof RunnerError && /timed out/.test(error.message),
  );

  assert.ok(Date.now() - started < 140);
});

test('fills an upload part across legal short reads', async () => {
  const source = Buffer.from('abcdefgh');
  const target = Buffer.alloc(source.length);
  let calls = 0;
  const handle = {
    async read(buffer, offset, length, position) {
      calls += 1;
      const bytesRead = Math.min(2, length, source.length - position);
      if (bytesRead > 0) source.copy(buffer, offset, position, position + bytesRead);
      return { bytesRead, buffer };
    },
  };

  assert.equal(await readFully(handle, target, 0), source.length);
  assert.deepEqual(target, source);
  assert.ok(calls > 1);
});

test('rejects using the same path for raw draft and run summary', async () => {
  const files = await fixture();
  await assert.rejects(
    runImport(
      { ...config(files), summaryPath: files.outputPath },
      new ApiClient(baseUrl, 'secret-token', { requestTimeoutSeconds: 5 }),
    ),
    (error) => error instanceof RunnerError && /different files/.test(error.message),
  );
  assert.equal(events.length, 0);
});
