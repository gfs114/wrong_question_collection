import {
  BadRequestException,
  Body,
  Controller,
  Delete,
  Get,
  Headers,
  HttpCode,
  HttpStatus,
  INestApplication,
  Param,
  Post,
  Put,
  Req,
  RequestTimeoutException,
  Res,
  StreamableFile,
  UnauthorizedException,
  UnsupportedMediaTypeException,
  UseGuards
} from '@nestjs/common';
import { AccessTokenGuard, AuthenticatedRequest } from '../auth/access-token.guard';
import {
  CompletePdfImportDto,
  AckImportArtifactsDto,
  ConfirmPdfImportDto,
  CreatePdfImportDto,
  ImportArtifactParamsDto,
  ImportJobParamsDto,
  ImportPartParamsDto
} from './import.dto';
import { MAX_UPLOAD_PART_BYTES } from './import.contracts';
import { ImportUploadAdmissionService } from './import-upload-admission.service';
import { ImportService } from './import.service';

interface AuthenticatedPrincipal {
  userId: string;
  deviceId: string;
}

interface DisconnectEvents {
  destroyed?: boolean;
  writableEnded?: boolean;
  once?(event: 'aborted' | 'close', listener: () => void): unknown;
  off?(event: 'aborted' | 'close', listener: () => void): unknown;
}

interface DisconnectAwareRequest extends AuthenticatedRequest, DisconnectEvents {
  aborted?: boolean;
  complete?: boolean;
  readableEnded?: boolean;
  res?: DisconnectEvents;
}

interface RawParserResponse {
  status(code: number): RawParserResponse;
  json(body: unknown): void;
}

interface ArtifactResponse extends DisconnectEvents {
  setHeader(name: string, value: string | number): void;
}

type RawParserNext = (error?: unknown) => void;
type RawParserErrorHandler = (
  error: unknown,
  request: unknown,
  response: RawParserResponse,
  next: RawParserNext
) => void;

const expressRuntime = require('express') as {
  raw(options: { type: string; limit: number }): (
    request: unknown,
    response: unknown,
    next: RawParserNext
  ) => void;
  json(options: { type: string; limit: number }): (
    request: unknown,
    response: unknown,
    next: RawParserNext
  ) => void;
};

export const importPartParserError: RawParserErrorHandler = (error, _request, response, next) => {
  const parserError = error as { status?: unknown; type?: unknown; code?: unknown };
  if (parserError.status === HttpStatus.PAYLOAD_TOO_LARGE || parserError.type === 'entity.too.large') {
    response.status(HttpStatus.PAYLOAD_TOO_LARGE).json({
      statusCode: HttpStatus.PAYLOAD_TOO_LARGE,
      code: 'PART_TOO_LARGE',
      message: 'Upload part exceeds the configured limit'
    });
    return;
  }
  const expectedMalformed = parserError.status === HttpStatus.BAD_REQUEST ||
    parserError.type === 'entity.parse.failed' || parserError.type === 'request.aborted' ||
    parserError.type === 'request.size.invalid' ||
    (typeof parserError.code === 'string' && parserError.code.startsWith('Z_'));
  if (expectedMalformed) {
    response.status(HttpStatus.BAD_REQUEST).json({
      statusCode: HttpStatus.BAD_REQUEST,
      code: 'MALFORMED_PART_BODY',
      message: 'Upload part body is malformed'
    });
    return;
  }
  next(error);
};

export function configureImportPartBodyParser(
  app: INestApplication,
  admission: ImportUploadAdmissionService,
  partBytes = MAX_UPLOAD_PART_BYTES
): void {
  app.use(
    '/v1/imports/pdf/:jobId/parts/:partIndex',
    admission.middleware(),
    expressRuntime.raw({ type: 'application/octet-stream', limit: partBytes }),
    importPartParserError
  );
}

export const IMPORT_CONFIRM_DEFAULT_MAX_BYTES = 2 * 1024 * 1024;
export const IMPORT_CONFIRM_MIN_BYTES = 64 * 1024;
export const IMPORT_CONFIRM_MAX_BYTES_LIMIT = 10 * 1024 * 1024;

export function effectiveImportConfirmMaxBytes(configuredBytes: number): number {
  if (!Number.isInteger(configuredBytes) ||
    configuredBytes < IMPORT_CONFIRM_MIN_BYTES || configuredBytes > IMPORT_CONFIRM_MAX_BYTES_LIMIT) {
    throw new Error('IMPORT_CONFIRM_MAX_BYTES must be an integer between 65536 and 10485760');
  }
  return configuredBytes;
}

export const importConfirmParserError: RawParserErrorHandler = (error, _request, response, next) => {
  const parserError = error as { status?: unknown; type?: unknown; code?: unknown };
  if (parserError.status === HttpStatus.PAYLOAD_TOO_LARGE || parserError.type === 'entity.too.large') {
    response.status(HttpStatus.PAYLOAD_TOO_LARGE).json({
      statusCode: HttpStatus.PAYLOAD_TOO_LARGE,
      code: 'CONFIRM_TOO_LARGE',
      message: 'Confirmation request exceeds the configured limit'
    });
    return;
  }
  const expectedMalformed = parserError.status === HttpStatus.BAD_REQUEST ||
    parserError.type === 'entity.parse.failed' || parserError.type === 'request.aborted' ||
    parserError.type === 'request.size.invalid' ||
    (typeof parserError.code === 'string' && parserError.code.startsWith('Z_'));
  if (expectedMalformed) {
    response.status(HttpStatus.BAD_REQUEST).json({
      statusCode: HttpStatus.BAD_REQUEST,
      code: 'MALFORMED_CONFIRM_BODY',
      message: 'Confirmation request body is malformed'
    });
    return;
  }
  next(error);
};

/**
 * Endpoint-scoped JSON parser for the confirm route: authentication runs before
 * any body buffering, the size cap is explicit and larger than the global
 * 100 KiB default (a confirmation carries up to 20 edited questions), and the
 * global limit for every other JSON route is left untouched.
 */
export function configureImportConfirmBodyParser(
  app: INestApplication,
  admission: ImportUploadAdmissionService,
  confirmBytes = IMPORT_CONFIRM_DEFAULT_MAX_BYTES
): void {
  app.use(
    '/v1/imports/pdf/:jobId/confirm',
    admission.middleware(),
    expressRuntime.json({ type: 'application/json', limit: confirmBytes }),
    importConfirmParserError
  );
}

@Controller('v1/imports/pdf')
@UseGuards(AccessTokenGuard)
export class ImportController {
  constructor(private readonly imports: ImportService) {}

  @Post()
  create(@Req() request: AuthenticatedRequest, @Body() input: CreatePdfImportDto) {
    const principal = this.principal(request);
    return this.imports.create(principal.userId, principal.deviceId, input);
  }

  @Put(':jobId/parts/:partIndex')
  @HttpCode(HttpStatus.NO_CONTENT)
  async uploadPart(
    @Req() request: AuthenticatedRequest,
    @Param() params: ImportPartParamsDto,
    @Headers('content-type') contentType: string | undefined,
    @Headers('x-part-sha256') partSha256: string | undefined,
    @Body() body: unknown
  ): Promise<void> {
    const mediaType = contentType?.split(';', 1)[0]?.trim().toLowerCase();
    if (mediaType !== 'application/octet-stream') {
      throw new UnsupportedMediaTypeException({
        statusCode: HttpStatus.UNSUPPORTED_MEDIA_TYPE,
        code: 'UNSUPPORTED_PART_MEDIA_TYPE',
        message: 'Upload parts require application/octet-stream'
      });
    }
    if (typeof partSha256 !== 'string' || !/^[0-9a-f]{64}$/.test(partSha256)) {
      throw new BadRequestException({
        statusCode: HttpStatus.BAD_REQUEST,
        code: 'INVALID_PART_SHA256',
        message: 'X-Part-Sha256 must be 64 lowercase hexadecimal characters'
      });
    }
    if (!Buffer.isBuffer(body) || body.length === 0) {
      throw new BadRequestException({
        statusCode: HttpStatus.BAD_REQUEST,
        code: 'EMPTY_PART',
        message: 'Upload part must not be empty'
      });
    }
    const principal = this.principal(request);
    await this.imports.uploadPart(
      principal.userId,
      principal.deviceId,
      params.jobId,
      params.partIndex,
      body,
      partSha256
    );
  }

  @Post(':jobId/complete')
  @HttpCode(HttpStatus.ACCEPTED)
  async complete(
    @Req() request: DisconnectAwareRequest,
    @Param() params: ImportJobParamsDto,
    @Body() input: CompletePdfImportDto
  ): Promise<{ jobId: string; status: string }> {
    const principal = this.principal(request);
    const disconnect = this.disconnectSignal(request);
    try {
      return await this.imports.complete(
        principal.userId, principal.deviceId, params.jobId, input, disconnect.signal
      );
    } finally {
      disconnect.release();
    }
  }

  @Get(':jobId')
  get(@Req() request: AuthenticatedRequest, @Param() params: ImportJobParamsDto) {
    return this.imports.get(this.principal(request).userId, params.jobId);
  }

  @Get(':jobId/draft')
  draft(@Req() request: AuthenticatedRequest, @Param() params: ImportJobParamsDto) {
    return this.imports.getDraft(this.principal(request).userId, params.jobId);
  }

  @Post(':jobId/confirm')
  confirm(
    @Req() request: AuthenticatedRequest,
    @Param() params: ImportJobParamsDto,
    @Body() input: ConfirmPdfImportDto
  ) {
    const principal = this.principal(request);
    return this.imports.confirm(principal.userId, principal.deviceId, params.jobId, input);
  }

  @Get(':jobId/artifacts/:artifactId')
  async downloadArtifact(
    @Req() request: DisconnectAwareRequest,
    @Res({ passthrough: true }) response: ArtifactResponse,
    @Param() params: ImportArtifactParamsDto
  ): Promise<StreamableFile> {
    const principal = this.principal(request);
    // Bind the disconnect listeners BEFORE the database lookup and file open:
    // a client abort while the artifact is being opened must still close the
    // file handle. close() is idempotent and safe to call before the handle
    // exists.
    let artifact: Awaited<ReturnType<ImportService['downloadArtifact']>> | undefined;
    let disconnected = false;
    let closed = false;
    const closeArtifact = () => {
      if (closed) return;
      closed = true;
      if (artifact !== undefined) void artifact.close().catch(() => undefined);
    };
    const onDisconnect = () => { disconnected = true; closeArtifact(); };
    request.once?.('aborted', onDisconnect);
    request.res?.once?.('close', onDisconnect);
    try {
      artifact = await this.imports.downloadArtifact(
        principal.userId, principal.deviceId, params.jobId, params.artifactId
      );
      if (disconnected) {
        // The client disconnected while the file was being opened; the handle
        // was not open when the listener ran, so close it here before refusing
        // the response.
        await artifact.close().catch(() => undefined);
        throw new RequestTimeoutException({
          statusCode: HttpStatus.REQUEST_TIMEOUT,
          code: 'IMPORT_REQUEST_ABORTED',
          message: 'Artifact download was cancelled before the file was opened'
        });
      }
    } finally {
      request.off?.('aborted', onDisconnect);
      request.res?.off?.('close', onDisconnect);
    }
    response.setHeader('Content-Type', 'image/jpeg');
    response.setHeader('Content-Length', artifact.size);
    response.setHeader('X-Content-SHA256', artifact.sha256);
    response.setHeader('ETag', `"${artifact.sha256}"`);
    response.setHeader('Cache-Control', 'no-store');
    artifact.stream.once('end', closeArtifact);
    artifact.stream.once('error', closeArtifact);
    return new StreamableFile(artifact.stream);
  }

  @Post(':jobId/artifacts/ack')
  @HttpCode(HttpStatus.NO_CONTENT)
  async acknowledgeArtifacts(
    @Req() request: AuthenticatedRequest,
    @Param() params: ImportJobParamsDto,
    @Body() input: AckImportArtifactsDto
  ): Promise<void> {
    const principal = this.principal(request);
    await this.imports.ackArtifacts(
      principal.userId, principal.deviceId, params.jobId, input.artifactIds
    );
  }

  @Delete(':jobId')
  @HttpCode(HttpStatus.NO_CONTENT)
  async cancel(
    @Req() request: DisconnectAwareRequest,
    @Param() params: ImportJobParamsDto
  ): Promise<void> {
    const principal = this.principal(request);
    const disconnect = this.disconnectSignal(request);
    try {
      await this.imports.cancel(
        principal.userId, principal.deviceId, params.jobId, disconnect.signal
      );
    } finally {
      disconnect.release();
    }
  }

  private principal(request: AuthenticatedRequest): AuthenticatedPrincipal {
    if (request.auth === undefined) {
      throw new UnauthorizedException({
        statusCode: HttpStatus.UNAUTHORIZED,
        code: 'AUTHENTICATED_PRINCIPAL_MISSING',
        message: 'Authenticated principal is missing'
      });
    }
    return { userId: request.auth.userId, deviceId: request.auth.deviceId };
  }

  private disconnectSignal(request: DisconnectAwareRequest): {
    signal: AbortSignal;
    release(): void;
  } {
    const controller = new AbortController();
    const abort = () => controller.abort();
    request.once?.('aborted', abort);
    request.res?.once?.('close', abort);
    const requestDisconnected =
      request.aborted === true ||
      (
        request.destroyed === true &&
        request.complete !== true &&
        request.readableEnded !== true
      );

    const responseDisconnected =
      request.res?.destroyed === true &&
      request.res.writableEnded !== true;

    if (requestDisconnected || responseDisconnected) {
      controller.abort();
    }
    return {
      signal: controller.signal,
      release: () => {
        request.off?.('aborted', abort);
        request.res?.off?.('close', abort);
      }
    };
  }
}

