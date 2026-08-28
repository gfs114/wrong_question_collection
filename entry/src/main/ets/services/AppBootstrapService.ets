import { Context } from '@kit.AbilityKit'
import { DatabaseService } from './DatabaseService'
import { SampleDataService } from './SampleDataService'
import { AccountSessionService } from './AccountSessionService'
import { SyncBootstrapService } from './SyncBootstrapService'

export class AppBootstrapService {
  private static initialization: Promise<void> | null = null

  static async initialize(context: Context): Promise<void> {
    let initialization: Promise<void> | null = AppBootstrapService.initialization
    if (initialization === null) {
      initialization = AppBootstrapService.run(context)
      AppBootstrapService.initialization = initialization
    }
    try {
      await initialization
    } catch (err) {
      if (AppBootstrapService.initialization === initialization) {
        AppBootstrapService.initialization = null
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Application bootstrap failed')
    }
  }

  private static async run(context: Context): Promise<void> {
    await DatabaseService.initialize(context)
    await SyncBootstrapService.enqueueLegacyLocalText(context)
    await SampleDataService.ensureSample(context)
    try {
      await AccountSessionService.restore(context)
    } catch {
      // Cloud session recovery must never block local-first app startup.
    }
  }
}
