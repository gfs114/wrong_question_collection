export interface ProxyAwareHttpServer {
  set(setting: string, value: number): void;
}

export function configureTrustedProxy(server: ProxyAwareHttpServer): void {
  server.set('trust proxy', 1);
}
