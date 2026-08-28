import { DeviceSessionStore } from '../auth/auth.contracts';
import { AuthenticatedRequest } from '../auth/access-token.guard';
import { TokenService } from '../auth/token.service';

const DEFAULT_MAX_CONCURRENT_UPLOADS = 4;

interface AdmissionRequest extends AuthenticatedRequest {
  headers: Record<string, string | string[] | undefined>;
  destroyed?: boolean;
}

interface AdmissionResponse {
  status(code: number): AdmissionResponse;
  json(body: unknown): void;
  once(event: 'finish' | 'close', listener: () => void): unknown;
  destroyed?: boolean;
  writableEnded?: boolean;
}

type AdmissionNext = (error?: unknown) => void;

export class ImportUploadAdmissionService {
  private activeUploads = 0;

  constructor(
    private readonly tokens: TokenService,
    private readonly sessions: DeviceSessionStore,
    private readonly maxConcurrent = DEFAULT_MAX_CONCURRENT_UPLOADS
  ) {
    if (!Number.isInteger(maxConcurrent) || maxConcurrent < 1) {
      throw new Error('Import upload concurrency must be a positive integer');
    }
  }

  middleware(): (
    request: AdmissionRequest,
    response: AdmissionResponse,
    next: AdmissionNext
  ) => Promise<void> {
    return async (request, response, next) => {
      const header = request.headers.authorization;
      const match = typeof header === 'string' ? /^Bearer ([^\s]+)$/.exec(header) : null;
      if (match === null) {
        response.status(401).json({
          statusCode: 401,
          message: 'Bearer access token is required'
        });
        return;
      }

      let auth: Awaited<ReturnType<TokenService['verifyAccess']>>;
      try {
        auth = await this.tokens.verifyAccess(match[1]);
      } catch {
        response.status(401).json({
          statusCode: 401,
          message: 'Invalid access token'
        });
        return;
      }
      let active: boolean;
      try {
        active = await this.sessions.isDeviceActive(
          auth.userId, auth.deviceId, auth.sessionGeneration
        );
      } catch {
        response.status(500).json({
          statusCode: 500,
          code: 'AUTH_SESSION_UNAVAILABLE',
          message: 'Authentication session could not be verified'
        });
        return;
      }
      if (!active) {
        response.status(401).json({
          statusCode: 401,
          message: 'Invalid access token'
        });
        return;
      }
      request.auth = auth;

      if (request.destroyed === true || response.destroyed === true || response.writableEnded === true) {
        return;
      }

      const encoding = request.headers['content-encoding'];
      if (encoding !== undefined &&
        (typeof encoding !== 'string' || encoding.trim().toLowerCase() !== 'identity')) {
        response.status(415).json({
          statusCode: 415,
          code: 'UNSUPPORTED_PART_CONTENT_ENCODING',
          message: 'Upload parts require identity content encoding'
        });
        return;
      }

      if (this.activeUploads >= this.maxConcurrent) {
        response.status(503).json({
          statusCode: 503,
          code: 'UPLOAD_CAPACITY_EXHAUSTED',
          message: 'Upload capacity is temporarily exhausted'
        });
        return;
      }

      this.activeUploads += 1;
      let released = false;
      const release = () => {
        if (released) return;
        released = true;
        this.activeUploads -= 1;
      };
      response.once('finish', release);
      response.once('close', release);
      try {
        next();
      } catch (error: unknown) {
        release();
        throw error;
      }
    };
  }
}
