#!/usr/bin/env node
'use strict';

/**
 * Run the deployed PDF import flow and save its unconfirmed review draft.
 *
 * This is a black-box diagnostic client. It never writes the database,
 * confirms a draft, cancels a job, or changes the import implementation.
 */

const { createHash, randomUUID } = require('node:crypto');
const {
  createReadStream,
  readFileSync,
} = require('node:fs');
const {
  mkdir,
  open,
  rename,
  stat,
  unlink,
} = require('node:fs/promises');
const http = require('node:http');
const https = require('node:https');
const path = require('node:path');
const process = require('node:process');
const { parseArgs } = require('node:util');

const MAX_PDF_BYTES = 209_715_200;
const MAX_PART_BYTES = 4_194_304;
const MAX_PART_COUNT = 3_200;
const MAX_RESPONSE_BYTES = 10 * 1024 * 1024;
const TERMINAL_FAILURE_STATUSES = new Set(['failed', 'cancelled', 'expired']);

class RunnerError extends Error {
  constructor(message) {
    super(message);
    this.name = 'RunnerError';
  }
}

class ApiClient {
  constructor(baseUrl, token, options = {}) {
    const normalizedToken = String(token ?? '').trim();
    let parsed;
    try {
      parsed = new URL(String(baseUrl ?? '').trim());
    } catch {
      throw new RunnerError('base URL must be a valid http:// or https:// URL');
    }
    if (!['http:', 'https:'].includes(parsed.protocol)) {
      throw new RunnerError('base URL must start with http:// or https://');
    }
    if (parsed.username || parsed.password || parsed.search || parsed.hash) {
      throw new RunnerError('base URL must not contain credentials, a query, or a fragment');
    }
    if (parsed.protocol === 'http:' && !isLoopbackHostname(parsed.hostname) && options.allowHttp !== true) {
      throw new RunnerError('cleartext HTTP for a non-loopback server requires explicit --allow-http');
    }
    if (!normalizedToken) throw new RunnerError('access token is required');

    const requestTimeoutSeconds = Number(options.requestTimeoutSeconds ?? 60);
    if (!Number.isFinite(requestTimeoutSeconds) || requestTimeoutSeconds <= 0) {
      throw new RunnerError('request timeout must be greater than zero');
    }
    this.baseUrl = parsed;
    this.basePath = parsed.pathname === '/' ? '' : parsed.pathname.replace(/\/$/, '');
    this.token = normalizedToken;
    this.requestTimeoutMilliseconds = requestTimeoutSeconds * 1000;
    this.ca = options.ca;
    this.rejectUnauthorized = options.rejectUnauthorized !== false;
  }

  async request(method, route, options = {}) {
    if (options.jsonBody !== undefined && options.body !== undefined) {
      throw new RunnerError('request cannot contain both JSON and raw bytes');
    }
    const endpoint = new URL(this.baseUrl);
    endpoint.pathname = `${this.basePath}${route}`;
    const expectedStatuses = options.expectedStatuses ?? [200];
    const requestTimeoutMilliseconds = options.timeoutSeconds === undefined
      ? this.requestTimeoutMilliseconds
      : Math.min(this.requestTimeoutMilliseconds, options.timeoutSeconds * 1000);
    if (!Number.isFinite(requestTimeoutMilliseconds) || requestTimeoutMilliseconds <= 0) {
      throw new RunnerError(`request timeout exhausted for ${method} ${route}`);
    }
    const headers = {
      accept: 'application/json',
      authorization: `Bearer ${this.token}`,
      'user-agent': 'wqc-math-pdf-e2e/1',
      ...(options.headers ?? {}),
    };
    let body = options.body;
    if (options.jsonBody !== undefined) {
      body = Buffer.from(JSON.stringify(options.jsonBody), 'utf8');
      headers['content-type'] = 'application/json';
    }
    if (body !== undefined) headers['content-length'] = String(body.length);

    return new Promise((resolve, reject) => {
      const transport = endpoint.protocol === 'https:' ? https : http;
      const request = transport.request(endpoint, {
        method,
        headers,
        timeout: requestTimeoutMilliseconds,
        ...(endpoint.protocol === 'https:' ? {
          ca: this.ca,
          rejectUnauthorized: this.rejectUnauthorized,
        } : {}),
      }, (response) => {
        const chunks = [];
        let size = 0;
        response.on('data', (chunk) => {
          size += chunk.length;
          if (size > MAX_RESPONSE_BYTES) {
            request.destroy(new RunnerError(`response too large for ${method} ${route}`));
            return;
          }
          chunks.push(chunk);
        });
        response.on('end', () => {
          clearTimeout(deadlineTimer);
          const responseBody = Buffer.concat(chunks);
          if (!expectedStatuses.includes(response.statusCode)) {
            reject(new RunnerError(
              `HTTP ${response.statusCode} for ${method} ${route}: ${safeErrorDetail(responseBody, this.token)}`,
            ));
            return;
          }
          if (responseBody.length === 0) {
            resolve(null);
            return;
          }
          try {
            resolve(JSON.parse(responseBody.toString('utf8')));
          } catch {
            reject(new RunnerError(`server returned invalid JSON for ${method} ${route}`));
          }
        });
      });
      const deadlineTimer = setTimeout(() => {
        request.destroy(new RunnerError(`request timed out for ${method} ${route}`));
      }, requestTimeoutMilliseconds);
      deadlineTimer.unref?.();
      request.on('timeout', () => request.destroy(new RunnerError(`request timed out for ${method} ${route}`)));
      request.on('error', (error) => {
        clearTimeout(deadlineTimer);
        reject(error instanceof RunnerError
          ? error
          : new RunnerError(
            `request failed for ${method} ${route}: ${redactSecret(error.message, this.token)}`,
          ));
      });
      if (body !== undefined) request.write(body);
      request.end();
    });
  }
}

function isLoopbackHostname(hostname) {
  const normalized = hostname.toLowerCase();
  return normalized === 'localhost'
    || normalized === '::1'
    || normalized === '[::1]'
    || /^127(?:\.\d{1,3}){3}$/.test(normalized);
}

function redactSecret(value, secret) {
  const text = String(value ?? '');
  if (!secret) return text;
  return text.split(secret).join('[REDACTED]');
}

function safeErrorDetail(body, secret) {
  try {
    const payload = JSON.parse(body.toString('utf8'));
    if (payload && typeof payload === 'object') {
      const fields = [payload.code, payload.message].filter((value) => typeof value === 'string');
      if (fields.length) return redactSecret(fields.join(': '), secret);
    }
  } catch {
    // Fall through to the stable message below.
  }
  return 'request rejected';
}

async function readFully(handle, buffer, position) {
  let offset = 0;
  while (offset < buffer.length) {
    const { bytesRead } = await handle.read(
      buffer,
      offset,
      buffer.length - offset,
      position + offset,
    );
    if (bytesRead === 0) break;
    offset += bytesRead;
  }
  return offset;
}

async function validateConfig(config) {
  if (path.resolve(config.outputPath) === path.resolve(config.summaryPath)) {
    throw new RunnerError('raw draft and run summary must use different files');
  }
  let sourceStat;
  try {
    sourceStat = await stat(config.pdfPath);
  } catch {
    throw new RunnerError(`PDF file does not exist: ${config.pdfPath}`);
  }
  if (!sourceStat.isFile()) throw new RunnerError(`PDF path is not a file: ${config.pdfPath}`);
  if (sourceStat.size < 1 || sourceStat.size > MAX_PDF_BYTES) {
    throw new RunnerError(`PDF size must be between 1 and ${MAX_PDF_BYTES} bytes`);
  }
  const handle = await open(config.pdfPath, 'r');
  try {
    const signature = Buffer.alloc(5);
    const { bytesRead } = await handle.read(signature, 0, signature.length, 0);
    if (bytesRead !== 5 || !signature.equals(Buffer.from('%PDF-'))) {
      throw new RunnerError('source file does not start with a PDF signature');
    }
  } finally {
    await handle.close();
  }

  if (!Number.isInteger(config.pageStart) || config.pageStart < 1 || config.pageStart > 20) {
    throw new RunnerError('page start must be an integer between 1 and 20');
  }
  if (
    !Number.isInteger(config.pageEnd)
    || config.pageEnd < config.pageStart
    || config.pageEnd > 20
    || config.pageEnd - config.pageStart + 1 > 20
  ) {
    throw new RunnerError('page range must be ordered and span at most 20 pages');
  }
  if (!Number.isFinite(config.pollIntervalSeconds) || config.pollIntervalSeconds < 0) {
    throw new RunnerError('poll interval cannot be negative');
  }
  if (!Number.isFinite(config.timeoutSeconds) || config.timeoutSeconds <= 0) {
    throw new RunnerError('poll timeout must be greater than zero');
  }
  if (config.expectedCount !== undefined
    && (!Number.isInteger(config.expectedCount) || config.expectedCount < 0)) {
    throw new RunnerError('expected question count must be a non-negative integer');
  }
  for (const label of config.expectedLabels ?? []) {
    if (typeof label !== 'string' || !label.trim()) {
      throw new RunnerError('expected labels must be non-empty strings');
    }
  }
  for (const assertion of config.expectedQuestionContains ?? []) {
    parseScopedAssertion(assertion, 2, '--expect-question-contains');
  }
  for (const assertion of config.rejectedQuestionContains ?? []) {
    parseScopedAssertion(assertion, 2, '--reject-question-contains');
  }
  for (const assertion of config.expectedQuestionOrder ?? []) {
    parseScopedAssertion(assertion, 3, '--expect-question-order');
  }
  if (!String(config.bankName ?? '').trim() || !String(config.subject ?? '').trim()) {
    throw new RunnerError('bank name and subject are required');
  }
  return sourceStat.size;
}

function sha256File(filePath) {
  return new Promise((resolve, reject) => {
    const digest = createHash('sha256');
    const stream = createReadStream(filePath);
    stream.on('data', (chunk) => digest.update(chunk));
    stream.on('error', (error) => reject(new RunnerError(`cannot hash PDF: ${error.message}`)));
    stream.on('end', () => resolve(digest.digest('hex')));
  });
}

function jobIdFrom(response) {
  const jobId = response?.jobId;
  if (typeof jobId !== 'string') throw new RunnerError('server response is missing jobId');
  const canonical = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  if (!canonical.test(jobId)) throw new RunnerError('server returned an invalid jobId');
  return jobId;
}

function partCountFrom(response) {
  const partCount = response?.partCount;
  if (!Number.isInteger(partCount) || partCount < 1 || partCount > MAX_PART_COUNT) {
    throw new RunnerError('server returned an invalid partCount');
  }
  return partCount;
}

async function writeJsonAtomic(filePath, payload) {
  const directory = path.dirname(filePath);
  await mkdir(directory, { recursive: true });
  const temporaryPath = path.join(directory, `.${path.basename(filePath)}.${randomUUID()}.tmp`);
  let handle;
  try {
    handle = await open(temporaryPath, 'wx', 0o600);
    await handle.writeFile(`${JSON.stringify(payload, null, 2)}\n`, 'utf8');
    await handle.sync();
    await handle.close();
    handle = undefined;
    await rename(temporaryPath, filePath);
  } finally {
    if (handle) await handle.close().catch(() => {});
    await unlink(temporaryPath).catch((error) => {
      if (error.code !== 'ENOENT') throw error;
    });
  }
}

function utcNow() {
  return new Date().toISOString();
}

function containsExpectedLabel(text, label) {
  const expected = label.trim();
  if (!/^例\s*\d+(?:\.\d+)+$/u.test(expected)) return text.includes(expected);
  const escaped = expected.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`${escaped}(?![\\d.])`, 'u').test(text);
}

function parseScopedAssertion(value, fieldCount, optionName) {
  const format = fieldCount === 2 ? 'LABEL::TEXT' : 'LABEL::FIRST::SECOND';
  if (typeof value !== 'string') throw new RunnerError(`${optionName} must use ${format}`);
  const fields = value.split('::');
  if (fields.length !== fieldCount || fields.some((field) => !field.trim())) {
    throw new RunnerError(`${optionName} must use ${format}`);
  }
  return fields.map((field) => field.trim());
}

function validateQuestionContent(questions, config) {
  const errors = [];
  const questionText = questions.map((question) => (
    question && typeof question === 'object' ? String(question.question ?? '') : ''
  ));

  function findScopedQuestion(label, assertionName) {
    const matches = questionText.filter((text) => containsExpectedLabel(text, label));
    if (matches.length === 0) {
      errors.push(`${assertionName} question not found: ${label}`);
      return null;
    }
    if (matches.length > 1) {
      errors.push(`${assertionName} question is ambiguous: ${label}`);
      return null;
    }
    return matches[0];
  }

  for (const assertion of config.expectedQuestionContains ?? []) {
    const [label, fragment] = parseScopedAssertion(assertion, 2, '--expect-question-contains');
    const text = findScopedQuestion(label, 'expected content');
    if (text !== null && !text.includes(fragment)) {
      errors.push(`missing expected content in ${label}: ${fragment}`);
    }
  }
  for (const assertion of config.rejectedQuestionContains ?? []) {
    const [label, fragment] = parseScopedAssertion(assertion, 2, '--reject-question-contains');
    const text = findScopedQuestion(label, 'rejected content');
    if (text !== null && text.includes(fragment)) {
      errors.push(`found rejected content in ${label}: ${fragment}`);
    }
  }
  for (const assertion of config.expectedQuestionOrder ?? []) {
    const [label, first, second] = parseScopedAssertion(assertion, 3, '--expect-question-order');
    const text = findScopedQuestion(label, 'expected order');
    if (text === null) continue;
    const firstIndex = text.indexOf(first);
    const secondIndex = text.indexOf(second);
    if (firstIndex < 0 || secondIndex < 0 || firstIndex >= secondIndex) {
      errors.push(`expected content order not found in ${label}: ${first} before ${second}`);
    }
  }
  return errors;
}

function makeSummary({
  config,
  jobId,
  sourceSize,
  sourceSha256,
  partCount,
  startedAt,
  elapsedSeconds,
  history,
  finalStatus,
  questionCount,
  validationErrors,
  failedStage = null,
  failureMessage = null,
}) {
  return {
    jobId,
    sourceFile: path.basename(config.pdfPath),
    sourceSize,
    sourceSha256,
    pageStart: config.pageStart,
    pageEnd: config.pageEnd,
    partCount,
    startedAt,
    finishedAt: utcNow(),
    elapsedSeconds: Number(elapsedSeconds.toFixed(3)),
    finalStatus,
    questionCount,
    statusHistory: history,
    validationErrors,
    failedStage,
    failureMessage,
  };
}

async function runImport(config, client, dependencies = {}) {
  const sleep = dependencies.sleep ?? ((milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)));
  const monotonic = dependencies.monotonic ?? (() => performance.now() / 1000);
  const sourceSize = await validateConfig(config);
  const sourceSha256 = await sha256File(config.pdfPath);
  const startedAt = utcNow();
  const started = monotonic();

  const created = await client.request('POST', '/v1/imports/pdf', {
    jsonBody: {
      bankName: config.bankName.trim(),
      subject: config.subject.trim(),
      pageStart: config.pageStart,
      pageEnd: config.pageEnd,
      sourceSize,
      sourceSha256,
    },
    expectedStatuses: [200, 201],
  });
  const jobId = jobIdFrom(created);
  let partCount = null;
  const history = [];
  let stage = 'create-response';
  let summaryWritten = false;

  try {
    partCount = partCountFrom(created);
    const partSize = Math.ceil(sourceSize / partCount);
    if (partSize > MAX_PART_BYTES) {
      throw new RunnerError('server partCount would exceed the maximum upload part size');
    }

    stage = 'upload';
    const source = await open(config.pdfPath, 'r');
    try {
      let position = 0;
      for (let index = 0; index < partCount; index += 1) {
        const buffer = Buffer.alloc(Math.min(partSize, sourceSize - position));
        const bytesRead = await readFully(source, buffer, position);
        if (bytesRead < 1) throw new RunnerError('server partCount would create an empty upload part');
        const part = buffer.subarray(0, bytesRead);
        position += bytesRead;
        await client.request('PUT', `/v1/imports/pdf/${jobId}/parts/${index}`, {
          body: part,
          headers: {
            'content-type': 'application/octet-stream',
            'x-part-sha256': createHash('sha256').update(part).digest('hex'),
          },
          expectedStatuses: [204],
        });
      }
      if (position !== sourceSize) {
        throw new RunnerError('server partCount did not consume the complete PDF');
      }
    } finally {
      await source.close();
    }

    stage = 'complete';
    await client.request('POST', `/v1/imports/pdf/${jobId}/complete`, {
      jsonBody: { partCount, sourceSha256 },
      expectedStatuses: [200, 202],
    });

    stage = 'poll';
    const pollingStarted = monotonic();
    const pollingDeadline = pollingStarted + config.timeoutSeconds;
    while (true) {
      const elapsedSeconds = monotonic() - started;
      const remainingSeconds = pollingDeadline - monotonic();
      if (remainingSeconds <= 0) {
        const summary = makeSummary({
          config, jobId, sourceSize, sourceSha256, partCount, startedAt,
          elapsedSeconds, history, finalStatus: 'timeout', questionCount: null,
          validationErrors: [], failedStage: stage,
          failureMessage: `timed out waiting for import job ${jobId}`,
        });
        await writeJsonAtomic(config.summaryPath, summary);
        summaryWritten = true;
        throw new RunnerError(`timed out waiting for import job ${jobId}`);
      }

      const statusPayload = await client.request('GET', `/v1/imports/pdf/${jobId}`, {
        expectedStatuses: [200],
        timeoutSeconds: remainingSeconds,
      });
      if (monotonic() > pollingDeadline) {
        const summary = makeSummary({
          config, jobId, sourceSize, sourceSha256, partCount, startedAt,
          elapsedSeconds: monotonic() - started, history, finalStatus: 'timeout', questionCount: null,
          validationErrors: [], failedStage: stage,
          failureMessage: `timed out waiting for import job ${jobId}`,
        });
        await writeJsonAtomic(config.summaryPath, summary);
        summaryWritten = true;
        throw new RunnerError(`timed out waiting for import job ${jobId}`);
      }
      const status = statusPayload?.status;
      if (typeof status !== 'string') throw new RunnerError('status response is missing status');
      history.push({
        elapsedSeconds: Number(elapsedSeconds.toFixed(3)),
        status,
        progress: statusPayload.progress ?? null,
      });
      if (status === 'review') break;
      if (TERMINAL_FAILURE_STATUSES.has(status)) {
        const message = `import job ${jobId} ended with status ${status}`;
        const summary = makeSummary({
          config, jobId, sourceSize, sourceSha256, partCount, startedAt,
          elapsedSeconds, history, finalStatus: status, questionCount: null,
          validationErrors: [], failedStage: stage, failureMessage: message,
        });
        await writeJsonAtomic(config.summaryPath, summary);
        summaryWritten = true;
        throw new RunnerError(message);
      }
      const sleepSeconds = Math.min(
        config.pollIntervalSeconds,
        Math.max(0, pollingDeadline - monotonic()),
      );
      await sleep(sleepSeconds * 1000);
    }

    stage = 'draft';
    const draft = await client.request('GET', `/v1/imports/pdf/${jobId}/draft`, {
      expectedStatuses: [200],
    });
    if (!draft || typeof draft !== 'object' || draft.jobId !== jobId) {
      throw new RunnerError('draft response does not match the import job');
    }
    if (!Array.isArray(draft.questions)) throw new RunnerError('draft response is missing questions');

    const validationErrors = [];
    if (config.expectedCount !== undefined && draft.questions.length !== config.expectedCount) {
      validationErrors.push(`expected ${config.expectedCount} questions, got ${draft.questions.length}`);
    }
    const combinedQuestions = draft.questions
      .map((question) => question && typeof question === 'object' ? String(question.question ?? '') : '')
      .join('\n');
    for (const label of config.expectedLabels ?? []) {
      if (!containsExpectedLabel(combinedQuestions, label)) {
        validationErrors.push(`missing expected label: ${label}`);
      }
    }
    validationErrors.push(...validateQuestionContent(draft.questions, config));

    const elapsedSeconds = monotonic() - started;
    const summary = makeSummary({
      config, jobId, sourceSize, sourceSha256, partCount, startedAt,
      elapsedSeconds, history, finalStatus: 'review',
      questionCount: draft.questions.length, validationErrors,
    });
    await writeJsonAtomic(config.outputPath, draft);
    await writeJsonAtomic(config.summaryPath, summary);
    summaryWritten = true;
    if (validationErrors.length) throw new RunnerError(validationErrors.join('; '));
    return { draft, summary };
  } catch (error) {
    const publicError = error instanceof RunnerError
      ? error
      : new RunnerError(`unexpected failure during ${stage}`);
    if (!summaryWritten) {
      const summary = makeSummary({
        config, jobId, sourceSize, sourceSha256, partCount, startedAt,
        elapsedSeconds: monotonic() - started, history, finalStatus: 'error',
        questionCount: null, validationErrors: [], failedStage: stage,
        failureMessage: publicError.message,
      });
      await writeJsonAtomic(config.summaryPath, summary);
    }
    throw publicError;
  }
}

function usage() {
  return `Usage:
  WQC_ACCESS_TOKEN='<token>' node server/scripts/math-pdf-import-e2e.cjs \\
    --base-url https://SERVER_IP \\
    --pdf /path/to/math-test.pdf \\
    --output server/test-results/before-fix-draft.json \\
    --expect-count 6 \\
    --expect-label 例1.1 --expect-label 例1.2 --expect-label 例1.3 \\
    --expect-label 例1.4 --expect-label 例1.5 --expect-label 例1.6 \\
    --expect-question-contains '例1.5::\\begin{cases}' \\
    --reject-question-contains '例1.5::f ( ) $' \\
    --expect-question-order '例1.6::\\frac{x}{1+x^2}::在' \\
    --ca-cert server/certs/server.crt

The script stops at review and never confirms or cancels the draft.

Options:
  --base-url URL       API origin; or set WQC_API_BASE_URL
  --token TOKEN        bearer token; prefer WQC_ACCESS_TOKEN to avoid process listings
  --pdf PATH           source PDF (required)
  --output PATH        raw draft JSON (default: before-fix-draft.json)
  --summary PATH       run metadata JSON (default: output name with .run.json)
  --bank-name NAME     import bank name (default: Math PDF E2E)
  --subject SUBJECT    import subject (default: Math)
  --page-start N       first absolute PDF page (default: 1)
  --page-end N         last absolute PDF page (default: 2)
  --poll-interval SEC  status polling interval (default: 3)
  --timeout SEC        maximum time from complete to review (default: 900)
  --request-timeout S  timeout for each HTTP request (default: 60)
  --expect-count N     fail after saving when draft count differs
  --expect-label TEXT  fail after saving when a label is absent; repeatable
  --expect-question-contains LABEL::TEXT
                        require text in the labeled question; repeatable
  --reject-question-contains LABEL::TEXT
                        reject text in the labeled question; repeatable
  --expect-question-order LABEL::FIRST::SECOND
                        require FIRST before SECOND in the labeled question; repeatable
  --ca-cert PATH       deployment CA/server certificate
  --insecure           disable TLS verification for an isolated test server only
  --allow-http         allow cleartext HTTP to a non-loopback test server
  --help               show this help
`;
}

function numberOption(value, name, fallback) {
  const result = value === undefined ? fallback : Number(value);
  if (!Number.isFinite(result)) throw new RunnerError(`${name} must be a number`);
  return result;
}

function defaultSummaryPath(outputPath) {
  return outputPath.endsWith('-draft.json')
    ? `${outputPath.slice(0, -'-draft.json'.length)}-run.json`
    : `${outputPath}.run.json`;
}

async function main(argv = process.argv.slice(2)) {
  const { values } = parseArgs({
    args: argv,
    strict: true,
    allowPositionals: false,
    options: {
      help: { type: 'boolean', short: 'h' },
      'base-url': { type: 'string' },
      token: { type: 'string' },
      pdf: { type: 'string' },
      output: { type: 'string' },
      summary: { type: 'string' },
      'bank-name': { type: 'string' },
      subject: { type: 'string' },
      'page-start': { type: 'string' },
      'page-end': { type: 'string' },
      'poll-interval': { type: 'string' },
      timeout: { type: 'string' },
      'request-timeout': { type: 'string' },
      'expect-count': { type: 'string' },
      'expect-label': { type: 'string', multiple: true, default: [] },
      'expect-question-contains': { type: 'string', multiple: true, default: [] },
      'reject-question-contains': { type: 'string', multiple: true, default: [] },
      'expect-question-order': { type: 'string', multiple: true, default: [] },
      'ca-cert': { type: 'string' },
      insecure: { type: 'boolean' },
      'allow-http': { type: 'boolean' },
    },
  });
  if (values.help) {
    process.stdout.write(usage());
    return 0;
  }
  const baseUrl = values['base-url'] ?? process.env.WQC_API_BASE_URL;
  const token = values.token ?? process.env.WQC_ACCESS_TOKEN;
  if (!baseUrl) throw new RunnerError('--base-url or WQC_API_BASE_URL is required');
  if (!token) throw new RunnerError('--token or WQC_ACCESS_TOKEN is required');
  if (!values.pdf) throw new RunnerError('--pdf is required');
  if (values['ca-cert'] && values.insecure) {
    throw new RunnerError('--ca-cert and --insecure cannot be used together');
  }
  if (values.insecure) {
    process.stderr.write('WARNING: TLS certificate verification is disabled\n');
  }
  if (values['allow-http']) {
    process.stderr.write('WARNING: bearer token may be sent over cleartext HTTP\n');
  }

  const outputPath = values.output ?? 'before-fix-draft.json';
  const expectedCount = values['expect-count'] === undefined
    ? undefined
    : numberOption(values['expect-count'], '--expect-count');
  let ca;
  if (values['ca-cert']) {
    try {
      ca = readFileSync(values['ca-cert']);
    } catch {
      throw new RunnerError(`cannot read CA certificate: ${values['ca-cert']}`);
    }
  }
  const result = await runImport({
    pdfPath: values.pdf,
    outputPath,
    summaryPath: values.summary ?? defaultSummaryPath(outputPath),
    bankName: values['bank-name'] ?? 'Math PDF E2E',
    subject: values.subject ?? 'Math',
    pageStart: numberOption(values['page-start'], '--page-start', 1),
    pageEnd: numberOption(values['page-end'], '--page-end', 2),
    pollIntervalSeconds: numberOption(values['poll-interval'], '--poll-interval', 3),
    timeoutSeconds: numberOption(values.timeout, '--timeout', 900),
    expectedCount,
    expectedLabels: values['expect-label'],
    expectedQuestionContains: values['expect-question-contains'],
    rejectedQuestionContains: values['reject-question-contains'],
    expectedQuestionOrder: values['expect-question-order'],
  }, new ApiClient(baseUrl, token, {
    requestTimeoutSeconds: numberOption(values['request-timeout'], '--request-timeout', 60),
    ca,
    rejectUnauthorized: !values.insecure,
    allowHttp: values['allow-http'] === true,
  }));

  process.stdout.write([
    `jobId: ${result.summary.jobId}`,
    `status: ${result.summary.finalStatus}`,
    `processingSeconds: ${result.summary.elapsedSeconds}`,
    `questions: ${result.summary.questionCount}`,
    `draft: ${outputPath}`,
    `runSummary: ${values.summary ?? defaultSummaryPath(outputPath)}`,
    '',
  ].join('\n'));
  return 0;
}

module.exports = {
  ApiClient,
  RunnerError,
  defaultSummaryPath,
  main,
  readFully,
  runImport,
};

if (require.main === module) {
  main().then(
    (exitCode) => { process.exitCode = exitCode; },
    (error) => {
      const message = error instanceof RunnerError ? error.message : 'unexpected runner failure';
      process.stderr.write(`ERROR: ${message}\n`);
      process.exitCode = 1;
    },
  );
}
