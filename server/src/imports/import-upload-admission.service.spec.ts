import { EventEmitter } from 'node:events';
import { DeviceSessionStore } from '../auth/auth.contracts';
import { TokenService } from '../auth/token.service';
import { ImportUploadAdmissionService } from './import-upload-admission.service';

function response() {
  const events = new EventEmitter();
  return Object.assign(events, {
    status: jest.fn().mockReturnThis(),
    json: jest.fn()
  });
}

function request(authorization = 'Bearer valid', contentEncoding?: string) {
  return {
    headers: {
      authorization,
      ...(contentEncoding === undefined ? {} : { 'content-encoding': contentEncoding })
    } as { authorization?: string; 'content-encoding'?: string },
    auth: undefined
  };
}

describe('ImportUploadAdmissionService', () => {
  const auth = {
    userId: 'user-1',
    deviceId: 'device-1',
    sessionGeneration: 'generation-1'
  };

  function admission(maxConcurrent = 1) {
    const tokens = {
      verifyAccess: jest.fn().mockResolvedValue(auth)
    } as unknown as jest.Mocked<TokenService>;
    const sessions = {
      isDeviceActive: jest.fn().mockResolvedValue(true)
    } as unknown as jest.Mocked<DeviceSessionStore>;
    return {
      middleware: new ImportUploadAdmissionService(tokens, sessions, maxConcurrent).middleware(),
      tokens,
      sessions
    };
  }

  it.each([
    [undefined, 'Bearer access token is required'],
    ['Bearer invalid', 'Invalid access token']
  ])('rejects %p before invoking the downstream raw parser', async (authorization, message) => {
    const fixture = admission();
    if (authorization === 'Bearer invalid') {
      fixture.tokens.verifyAccess.mockRejectedValueOnce(new Error('private JWT details'));
    }
    const incoming = request(authorization);
    if (authorization === undefined) delete incoming.headers.authorization;
    const outgoing = response();
    const rawParser = jest.fn();

    await fixture.middleware(incoming, outgoing, rawParser);

    expect(rawParser).not.toHaveBeenCalled();
    expect(outgoing.status).toHaveBeenCalledWith(401);
    expect(outgoing.json).toHaveBeenCalledWith({ statusCode: 401, message });
    expect(JSON.stringify(outgoing.json.mock.calls)).not.toContain('private JWT details');
  });

  it('rejects over-budget uploads before parsing and releases capacity on finish or close', async () => {
    const fixture = admission(1);
    const firstResponse = response();
    const firstParser = jest.fn();
    await fixture.middleware(request(), firstResponse, firstParser);
    expect(firstParser).toHaveBeenCalledTimes(1);

    const rejectedResponse = response();
    const rejectedParser = jest.fn();
    await fixture.middleware(request(), rejectedResponse, rejectedParser);
    expect(rejectedParser).not.toHaveBeenCalled();
    expect(rejectedResponse.status).toHaveBeenCalledWith(503);
    expect(rejectedResponse.json).toHaveBeenCalledWith({
      statusCode: 503,
      code: 'UPLOAD_CAPACITY_EXHAUSTED',
      message: 'Upload capacity is temporarily exhausted'
    });

    firstResponse.emit('close');
    firstResponse.emit('finish');
    const retryParser = jest.fn();
    await fixture.middleware(request(), response(), retryParser);
    expect(retryParser).toHaveBeenCalledTimes(1);
  });

  it('releases upload capacity when downstream parsing throws synchronously', async () => {
    const fixture = admission(1);
    await expect(fixture.middleware(request(), response(), () => {
      throw new Error('parser failed');
    })).rejects.toThrow('parser failed');

    const retryParser = jest.fn();
    await fixture.middleware(request(), response(), retryParser);
    expect(retryParser).toHaveBeenCalledTimes(1);
  });

  it('does not admit or leak capacity when the request disconnects during token verification', async () => {
    const fixture = admission(1);
    let finishVerification: (value: typeof auth) => void = () => undefined;
    fixture.tokens.verifyAccess.mockReturnValueOnce(new Promise((resolve) => {
      finishVerification = resolve;
    }));
    const incoming = Object.assign(request(), { destroyed: false });
    const rawParser = jest.fn();
    const pending = fixture.middleware(incoming, response(), rawParser);
    incoming.destroyed = true;
    finishVerification(auth);
    await pending;

    expect(rawParser).not.toHaveBeenCalled();
    const retryParser = jest.fn();
    await fixture.middleware(request(), response(), retryParser);
    expect(retryParser).toHaveBeenCalledTimes(1);
  });

  it('rejects an inactive authenticated device before invoking the raw parser', async () => {
    const fixture = admission();
    fixture.sessions.isDeviceActive.mockResolvedValueOnce(false);
    const outgoing = response();
    const rawParser = jest.fn();

    await fixture.middleware(request(), outgoing, rawParser);

    expect(rawParser).not.toHaveBeenCalled();
    expect(outgoing.status).toHaveBeenCalledWith(401);
  });

  it('returns a safe server error when session verification infrastructure fails without parsing', async () => {
    const fixture = admission();
    fixture.sessions.isDeviceActive.mockRejectedValueOnce(new Error('private database endpoint'));
    const outgoing = response();
    const rawParser = jest.fn();

    await fixture.middleware(request(), outgoing, rawParser);

    expect(rawParser).not.toHaveBeenCalled();
    expect(outgoing.status).toHaveBeenCalledWith(500);
    expect(outgoing.json).toHaveBeenCalledWith({
      statusCode: 500,
      code: 'AUTH_SESSION_UNAVAILABLE',
      message: 'Authentication session could not be verified'
    });
    expect(JSON.stringify(outgoing.json.mock.calls)).not.toContain('private database endpoint');
  });

  it('rejects non-identity content encoding before invoking the raw parser', async () => {
    const fixture = admission();
    const outgoing = response();
    const rawParser = jest.fn();

    await fixture.middleware(request('Bearer valid', 'gzip'), outgoing, rawParser);

    expect(rawParser).not.toHaveBeenCalled();
    expect(outgoing.status).toHaveBeenCalledWith(415);
    expect(outgoing.json).toHaveBeenCalledWith({
      statusCode: 415,
      code: 'UNSUPPORTED_PART_CONTENT_ENCODING',
      message: 'Upload parts require identity content encoding'
    });
  });
});
