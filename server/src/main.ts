import 'reflect-metadata';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { NestFactory } from '@nestjs/core';
import {
  configureImportConfirmBodyParser,
  configureImportPartBodyParser,
  effectiveImportConfirmMaxBytes
} from './imports/import.controller';
import { ImportUploadAdmissionService } from './imports/import-upload-admission.service';
import { effectiveImportPartBytes } from './imports/import.service';
import { configureTrustedProxy, ProxyAwareHttpServer } from './security/trusted-proxy';

const expressRuntime = require('express') as {
  json(options: { limit: number }): (request: unknown, response: unknown, next: (error?: unknown) => void) => void;
};

/** The Nest default; every JSON route except the endpoint-scoped confirm parser keeps it. */
const DEFAULT_JSON_BODY_BYTES = 100 * 1024;

export function configureHttpApplication(app: INestApplication): void {
  const httpServer = app.getHttpAdapter().getInstance() as ProxyAwareHttpServer;
  const config = app.get(ConfigService);
  configureTrustedProxy(httpServer);
  const admission = app.get(ImportUploadAdmissionService);
  configureImportPartBodyParser(
    app,
    admission,
    effectiveImportPartBytes(config.getOrThrow<number>('IMPORT_PART_BYTES'))
  );
  // The confirm route is registered before the global JSON parser so its
  // endpoint-scoped, auth-first, explicitly sized parser wins for that route
  // while every other JSON route keeps the default 100 KiB limit.
  configureImportConfirmBodyParser(
    app,
    admission,
    effectiveImportConfirmMaxBytes(config.getOrThrow<number>('IMPORT_CONFIRM_MAX_BYTES'))
  );
  app.use(expressRuntime.json({ limit: DEFAULT_JSON_BODY_BYTES }));
  app.useGlobalPipes(
    new ValidationPipe({
      transform: true,
      whitelist: true,
      forbidNonWhitelisted: true
    })
  );
}

export async function bootstrap(): Promise<void> {
  const { AppModule } = await import('./app.module');
  const app = await NestFactory.create(AppModule, { bufferLogs: true, bodyParser: false });
  configureHttpApplication(app);
  app.enableShutdownHooks();
  const config = app.get(ConfigService);
  await app.listen(config.getOrThrow<number>('PORT'), '0.0.0.0');
}

if (require.main === module) {
  void bootstrap();
}
