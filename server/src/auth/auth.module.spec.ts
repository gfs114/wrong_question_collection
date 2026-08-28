import { MODULE_METADATA } from '@nestjs/common/constants';
import { DEVICE_SESSION_STORE } from './auth.contracts';
import { AuthModule } from './auth.module';

describe('AuthModule', () => {
  it('exports the device session store required by guards in importing modules', () => {
    const exportedProviders = Reflect.getMetadata(
      MODULE_METADATA.EXPORTS,
      AuthModule
    ) as unknown[];

    expect(exportedProviders).toContain(DEVICE_SESSION_STORE);
  });
});
