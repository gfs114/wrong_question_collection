import { Controller, Get } from '@nestjs/common';
import { HealthService, HealthStatus, ReadinessStatus } from './health.service';

@Controller('health')
export class HealthController {
  constructor(private readonly healthService: HealthService) {}

  @Get()
  getStatus(): HealthStatus {
    return this.healthService.getStatus();
  }


  @Get('ready')
  getReadiness(): Promise<ReadinessStatus> {
    return this.healthService.getReadiness();
  }
}
