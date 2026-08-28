import { Injectable, ServiceUnavailableException } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';

export interface HealthStatus {
  status: 'ok';
  service: 'wrong-question-api';
}

export interface ReadinessStatus extends HealthStatus {
  database: 'ready';
}

@Injectable()
export class HealthService {
  constructor(@InjectDataSource() private readonly dataSource: DataSource) {}

  getStatus(): HealthStatus {
    return {
      status: 'ok',
      service: 'wrong-question-api'
    };
  }

  async getReadiness(): Promise<ReadinessStatus> {
    try {
      await this.dataSource.query('SELECT 1');
      return {
        ...this.getStatus(),
        database: 'ready'
      };
    } catch {
      throw new ServiceUnavailableException('Database is not ready');
    }
  }
}
