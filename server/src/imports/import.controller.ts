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
    @Req() request: AuthenticatedRequest,
    @Res({ passthrough: true }) response: ArtifactResponse,
    @Param() params: ImportArtifactParamsDto
  ): Promise<StreamableFile> {
    const principal = this.principal(request);
    const artifact = await this.imports.downloadArtifact(
      principal.userId, principal.deviceId, params.jobId, params.artifactId
    );
    response.setHeader('Content-Type', 'image/jpeg');
    response.setHeader('Content-Length', artifact.size);
    response.setHeader('X-Content-SHA256', artifact.sha256);
    response.setHeader('ETag', `"${artifact.sha256}"`);
    response.setHeader('Cache-Control', 'no-store');
    const close = () => { void artifact.close().catch(() => undefined); };
    response.once?.('close', close);
    artifact.stream.once('end', close);
    artifact.stream.once('error', close);
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
    if (request.aborted === true || request.destroyed === true ||
      (request.res?.destroyed === true && request.res.writableEnded !== true)) {
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
