import 'reflect-metadata';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { NestFactory } from '@nestjs/core';
import { configureImportPartBodyParser } from './imports/import.controller';
import { ImportUploadAdmissionService } from './imports/import-upload-admission.service';
import { effectiveImportPartBytes } from './imports/import.service';
import { configureTrustedProxy, ProxyAwareHttpServer } from './security/trusted-proxy';

export function configureHttpApplication(app: INestApplication): void {
  const httpServer = app.getHttpAdapter().getInstance() as ProxyAwareHttpServer;
  const config = app.get(ConfigService);
  configureTrustedProxy(httpServer);
  configureImportPartBodyParser(
    app,
    app.get(ImportUploadAdmissionService),
    effectiveImportPartBytes(config.getOrThrow<number>('IMPORT_PART_BYTES'))
  );
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
  const app = await NestFactory.create(AppModule, { bufferLogs: true });
  configureHttpApplication(app);
  app.enableShutdownHooks();
  const config = app.get(ConfigService);
  await app.listen(config.getOrThrow<number>('PORT'), '0.0.0.0');
}

if (require.main === module) {
  void bootstrap();
}
