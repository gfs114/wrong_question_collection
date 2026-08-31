import { Context } from '@kit.AbilityKit'
import { fileIo as fs, hash } from '@kit.CoreFileKit'
import { ApiHttpError } from '../models/ApiModels'
import {
  CloudImportArtifactAckRequest,
  CloudImportDraft,
  CloudImportFileMetadata,
  CloudImportJob,
  CloudImportRetryPolicy,
  CloudImportStatus,
  CloudImportUploadPolicy,
  CloudImportUploadRequest,
  CompleteCloudImportRequest,
  CompleteCloudImportResult,
  ConfirmCloudImportRequest,
  ConfirmImportResult,
  CreateCloudImportRequest
} from '../models/CloudImportModels'
import { AccountSessionService } from './AccountSessionService'
import { ApiHttpClient } from './ApiHttpClient'
import { CloudImportApi, PART_BYTES } from './CloudImportApi'

export class CloudImportService {
  private static preparingJobIds: Set<string> = new Set<string>()
  private static activeJobIds: Set<string> = new Set<string>()
  private static cancelledJobIds: Set<string> = new Set<string>()

  static async createJob(context: Context, request: CloudImportUploadRequest): Promise<CloudImportJob> {
    const metadata: CloudImportFileMetadata = await CloudImportService.inspectFile(request.pdfPath)
    return CloudImportService.createJobWithMetadata(context, request, metadata)
  }

  static async upload(context: Context, pdfPath: string,
    job: CloudImportJob): Promise<CompleteCloudImportResult> {
    return CloudImportService.resumeUpload(context, pdfPath, job, 0)
  }

  static async resumeUpload(context: Context, pdfPath: string, job: CloudImportJob,
    firstMissingPart: number): Promise<CompleteCloudImportResult> {
    if (job.status !== CloudImportStatus.UPLOADING) {
      throw new Error('Cloud import job is not accepting parts')
    }
    if (CloudImportService.preparingJobIds.has(job.jobId) ||
      CloudImportService.activeJobIds.has(job.jobId)) {
      throw new Error('Cloud import upload is already active')
    }
    CloudImportService.preparingJobIds.add(job.jobId)
    try {
      const metadata: CloudImportFileMetadata = await CloudImportService.inspectFile(pdfPath)
      const expectedPartCount: number = CloudImportUploadPolicy.partCount(
        metadata.sourceSize, PART_BYTES)
      if (job.sourceSize !== metadata.sourceSize || job.sourceSha256 !== metadata.sourceSha256 ||
        job.partCount !== expectedPartCount) {
        throw new Error('Cloud import resume PDF does not match the job')
      }
      const startPart: number = CloudImportUploadPolicy.firstMissingPart(
        firstMissingPart, job.partCount)
      return await CloudImportService.uploadPartsAndComplete(context, pdfPath, job, startPart)
    } finally {
      CloudImportService.preparingJobIds.delete(job.jobId)
    }
  }

  static async getJob(context: Context, jobId: string): Promise<CloudImportJob> {
    return CloudImportService.authorized<CloudImportJob>(context,
      (accessToken: string): Promise<CloudImportJob> => {
        return CloudImportApi.getJob(jobId, accessToken)
      })
  }

  static async getDraft(context: Context, jobId: string): Promise<CloudImportDraft> {
    return CloudImportService.authorized<CloudImportDraft>(context,
      (accessToken: string): Promise<CloudImportDraft> => {
        return CloudImportApi.getDraft(jobId, accessToken)
      })
  }

  static async confirm(context: Context, jobId: string,
    request: ConfirmCloudImportRequest): Promise<ConfirmImportResult> {
    return CloudImportService.authorized<ConfirmImportResult>(context,
      (accessToken: string): Promise<ConfirmImportResult> => {
        return CloudImportApi.confirm(jobId, request, accessToken)
      })
  }

  static async downloadArtifact(context: Context, jobId: string, artifactId: string,
    expectedSize: number, expectedSha256: string): Promise<ArrayBuffer> {
    if (!Number.isInteger(expectedSize) || expectedSize <= 0 ||
      !CloudImportUploadPolicy.isSha256(expectedSha256)) {
      throw new Error('Invalid cloud import artifact metadata')
    }
    const content: ArrayBuffer = await CloudImportService.authorized<ArrayBuffer>(context,
      (accessToken: string): Promise<ArrayBuffer> => {
        return CloudImportApi.downloadArtifact(jobId, artifactId, expectedSize, accessToken)
      })
    if (content.byteLength !== expectedSize ||
      CloudImportService.sha256Bytes(content) !== expectedSha256) {
      throw new Error('Cloud import artifact verification failed')
    }
    return content
  }

  static async acknowledgeArtifacts(context: Context, jobId: string,
    artifactIds: Array<string>): Promise<void> {
    const request: CloudImportArtifactAckRequest = new CloudImportArtifactAckRequest(artifactIds)
    return CloudImportService.authorized<void>(context,
      (accessToken: string): Promise<void> => {
        return CloudImportApi.acknowledgeArtifacts(jobId, request, accessToken)
      })
  }

  static async cancel(context: Context, jobId: string): Promise<void> {
    const preparing: boolean = CloudImportService.preparingJobIds.has(jobId)
    const active: boolean = CloudImportService.activeJobIds.has(jobId)
    if (preparing || active) {
      CloudImportService.cancelledJobIds.add(jobId)
    }
    if (active) {
      ApiHttpClient.cancelRequest(jobId)
    }
    return CloudImportService.authorized<void>(context,
      (accessToken: string): Promise<void> => {
        return CloudImportApi.cancel(jobId, accessToken)
      })
  }

  private static async uploadPartsAndComplete(context: Context, pdfPath: string,
    job: CloudImportJob, firstMissingPart: number): Promise<CompleteCloudImportResult> {
    if (CloudImportService.activeJobIds.has(job.jobId)) {
      throw new Error('Cloud import upload is already active')
    }
    CloudImportService.activeJobIds.add(job.jobId)
    let file: fs.File | null = null
    try {
      CloudImportService.ensureNotCancelled(job.jobId)
      file = await fs.open(pdfPath, fs.OpenMode.READ_ONLY)
      const info: fs.Stat = await fs.stat(file.fd)
      if (info.size !== job.sourceSize) {
        throw new Error('Cloud import PDF size changed')
      }
      const offset: number = firstMissingPart * PART_BYTES
      const actualOffset: number = fs.lseek(file.fd, offset, fs.WhenceType.SEEK_SET)
      if (actualOffset !== offset) {
        throw new Error('Cloud import PDF seek failed')
      }
      for (let partIndex: number = firstMissingPart; partIndex < job.partCount; partIndex++) {
        CloudImportService.ensureNotCancelled(job.jobId)
        const expectedLength: number = CloudImportUploadPolicy.partLength(
          job.sourceSize, PART_BYTES, partIndex)
        const body: ArrayBuffer = await CloudImportService.readExact(file.fd, expectedLength)
        CloudImportService.ensureNotCancelled(job.jobId)
        const partSha256: string = CloudImportService.sha256Bytes(body)
        await CloudImportService.authorized<void>(context,
          (accessToken: string): Promise<void> => {
            CloudImportService.ensureNotCancelled(job.jobId)
            return CloudImportApi.uploadPart(job.jobId, partIndex, body, partSha256, accessToken)
          })
      }
      CloudImportService.ensureNotCancelled(job.jobId)
      const finalInfo: fs.Stat = await fs.stat(file.fd)
      if (finalInfo.size !== job.sourceSize) {
        throw new Error('Cloud import PDF changed during upload')
      }
      const completeRequest: CompleteCloudImportRequest = new CompleteCloudImportRequest(
        job.partCount, job.sourceSha256)
      return await CloudImportService.authorized<CompleteCloudImportResult>(context,
        async (accessToken: string): Promise<CompleteCloudImportResult> => {
          CloudImportService.ensureNotCancelled(job.jobId)
          const result: CompleteCloudImportResult = await CloudImportApi.complete(
            job.jobId, completeRequest, accessToken)
          CloudImportService.ensureNotCancelled(job.jobId)
          return result
        })
    } finally {
      try {
        if (file !== null) {
          await fs.close(file)
        }
      } finally {
        CloudImportService.activeJobIds.delete(job.jobId)
        CloudImportService.cancelledJobIds.delete(job.jobId)
      }
    }
  }

  private static async createJobWithMetadata(context: Context, request: CloudImportUploadRequest,
    metadata: CloudImportFileMetadata): Promise<CloudImportJob> {
    const createRequest: CreateCloudImportRequest = new CreateCloudImportRequest(
      request.bankName, request.subject, request.pageStart, request.pageEnd,
      metadata.sourceSize, metadata.sourceSha256)
    const job: CloudImportJob = await CloudImportService.authorized<CloudImportJob>(context,
      (accessToken: string): Promise<CloudImportJob> => {
        return CloudImportApi.create(createRequest, accessToken)
      })
    const expectedPartCount: number = CloudImportUploadPolicy.partCount(
      metadata.sourceSize, PART_BYTES)
    if (job.sourceSize !== metadata.sourceSize || job.sourceSha256 !== metadata.sourceSha256 ||
      job.partCount !== expectedPartCount || job.status !== CloudImportStatus.UPLOADING) {
      throw new Error('Cloud import creation response does not match the PDF')
    }
    return job
  }

  private static async inspectFile(pdfPath: string): Promise<CloudImportFileMetadata> {
    const file: fs.File = await fs.open(pdfPath, fs.OpenMode.READ_ONLY)
    let sourceSize: number = 0
    try {
      const info: fs.Stat = await fs.stat(file.fd)
      sourceSize = info.size
      if (!Number.isInteger(sourceSize) || sourceSize <= 0) {
        throw new Error('Cloud import PDF is empty')
      }
    } finally {
      await fs.close(file)
    }
    const sourceSha256: string = (await hash.hash(pdfPath, 'sha256')).toLowerCase()
    if (!CloudImportUploadPolicy.isSha256(sourceSha256)) {
      throw new Error('Cloud import PDF hash failed')
    }
    const finalInfo: fs.Stat = await fs.stat(pdfPath)
    if (finalInfo.size !== sourceSize) {
      throw new Error('Cloud import PDF changed during hashing')
    }
    return new CloudImportFileMetadata(sourceSize, sourceSha256)
  }

  private static async readExact(fd: number, expectedLength: number): Promise<ArrayBuffer> {
    const body: ArrayBuffer = new ArrayBuffer(expectedLength)
    const destination: Uint8Array = new Uint8Array(body)
    let totalRead: number = 0
    while (totalRead < expectedLength) {
      const readBuffer: ArrayBuffer = new ArrayBuffer(expectedLength - totalRead)
      const bytesRead: number = await fs.read(fd, readBuffer)
      if (!Number.isInteger(bytesRead) || bytesRead <= 0 ||
        bytesRead > readBuffer.byteLength) {
        throw new Error('Cloud import PDF ended before the part was complete')
      }
      const exactRead: ArrayBuffer = readBuffer.slice(0, bytesRead)
      destination.set(new Uint8Array(exactRead), totalRead)
      totalRead += bytesRead
    }
    return body
  }

  private static sha256Bytes(content: ArrayBuffer): string {
    const stream: hash.HashStream = hash.createHash('sha256')
    stream.update(content)
    return stream.digest().toLowerCase()
  }

  private static ensureNotCancelled(jobId: string): void {
    if (CloudImportService.cancelledJobIds.has(jobId)) {
      throw new Error('Cloud import upload cancelled')
    }
  }

  private static async authorized<T>(context: Context,
    operation: (accessToken: string) => Promise<T>): Promise<T> {
    const accessToken: string = await AccountSessionService.accessToken(context)
    try {
      return await operation(accessToken)
    } catch (err) {
      if (err instanceof ApiHttpError &&
        CloudImportRetryPolicy.shouldRefresh(err.statusCode, false)) {
        const refreshedToken: string = await AccountSessionService.refresh(context)
        return operation(refreshedToken)
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Cloud import request failed')
    }
  }
}
