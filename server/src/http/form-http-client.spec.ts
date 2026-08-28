import { FetchFormHttpClient } from './form-http-client';

describe('FetchFormHttpClient', () => {
  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('applies a timeout to outbound Huawei requests', async () => {
    const signal = new AbortController().signal;
    const timeout = jest.spyOn(AbortSignal, 'timeout').mockReturnValue(signal);
    const fetchMock = jest.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('{"ok":true}', { status: 200 })
    );

    await new FetchFormHttpClient().postForm(
      'https://accounts.example.test/token',
      new URLSearchParams({ code: 'authorization-code' })
    );

    expect(timeout).toHaveBeenCalledWith(10_000);
    expect(fetchMock).toHaveBeenCalledWith(
      'https://accounts.example.test/token',
      expect.objectContaining({ signal })
    );
  });
});
