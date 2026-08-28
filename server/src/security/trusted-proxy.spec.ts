import { configureTrustedProxy } from './trusted-proxy';

describe('configureTrustedProxy', () => {
  it('trusts exactly the single Caddy proxy hop', () => {
    const server = { set: jest.fn() };

    configureTrustedProxy(server);

    expect(server.set).toHaveBeenCalledWith('trust proxy', 1);
  });
});
