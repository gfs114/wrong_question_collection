import {
  CloudImportArtifact,
  CloudImportArtifactAckRequest,
  CloudImportDraft,
  CloudImportDraftQuestion,
  CloudImportJob,
  CloudImportProgress,
  CloudImportStatus,
  CloudImportUploadPolicy,
  CompleteCloudImportRequest,
  CompleteCloudImportResult,
  ConfirmCloudImportRequest,
  ConfirmedImportArtifact,
  ConfirmImportQuestionResult,
  ConfirmImportResult,
  CreateCloudImportRequest
} from '../models/CloudImportModels'
import { ApiHttpClient } from './ApiHttpClient'

export const PART_BYTES: number = 4 * 1024 * 1024

export class CloudImportApi {
  static async create(request: CreateCloudImportRequest, accessToken: string): Promise<CloudImportJob> {
    const response: CloudImportJob = await ApiHttpClient.authorizedPostExpecting<CloudImportJob>(
      '/v1/imports/pdf', request, accessToken, 201)
    return CloudImportApi.copyJob(response)
  }

  static async uploadPart(jobId: string, partIndex: number, body: ArrayBuffer,
    sha256: string, accessToken: string): Promise<void> {
    if (!Number.isInteger(partIndex) || partIndex < 0) {
      throw new Error('Invalid cloud import part index')
    }
    if (body.byteLength <= 0 || body.byteLength > PART_BYTES ||
      !CloudImportUploadPolicy.isSha256(sha256)) {
      throw new Error('Invalid cloud import part')
    }
    const path: string = CloudImportApi.jobPath(jobId) + '/parts/' + partIndex.toString()
    await ApiHttpClient.authorizedBinaryPut(path, body, sha256, accessToken, 204, jobId)
  }

  static async complete(jobId: string, request: CompleteCloudImportRequest,
    accessToken: string): Promise<CompleteCloudImportResult> {
    const response: CompleteCloudImportResult =
      await ApiHttpClient.authorizedPostExpecting<CompleteCloudImportResult>(
        CloudImportApi.jobPath(jobId) + '/complete', request, accessToken, 202, jobId)
    return new CompleteCloudImportResult(response.jobId, CloudImportApi.status(response.status))
  }

  static async getJob(jobId: string, accessToken: string): Promise<CloudImportJob> {
    const response: CloudImportJob = await ApiHttpClient.authorizedGetExpecting<CloudImportJob>(
      CloudImportApi.jobPath(jobId), accessToken, 200)
    return CloudImportApi.copyJob(response)
  }

  static async getDraft(jobId: string, accessToken: string): Promise<CloudImportDraft> {
    const response: CloudImportDraft = await ApiHttpClient.authorizedGetExpecting<CloudImportDraft>(
      CloudImportApi.jobPath(jobId) + '/draft', accessToken, 200)
    return CloudImportApi.copyDraft(response)
  }

  static async confirm(jobId: string, request: ConfirmCloudImportRequest,
    accessToken: string): Promise<ConfirmImportResult> {
    const response: ConfirmImportResult =
      await ApiHttpClient.authorizedPostExpecting<ConfirmImportResult>(
        CloudImportApi.jobPath(jobId) + '/confirm', request, accessToken, 201)
    return CloudImportApi.copyConfirmResult(response)
  }

  static async downloadArtifact(jobId: string, artifactId: string, maxResponseBytes: number,
    accessToken: string): Promise<ArrayBuffer> {
    const path: string = CloudImportApi.jobPath(jobId) + '/artifacts/' +
      CloudImportApi.identifier(artifactId)
    return ApiHttpClient.authorizedBinaryDownload(path, accessToken, 200, maxResponseBytes)
  }

  static async acknowledgeArtifacts(jobId: string, request: CloudImportArtifactAckRequest,
    accessToken: string): Promise<void> {
    await ApiHttpClient.authorizedPostExpecting<void>(
      CloudImportApi.jobPath(jobId) + '/artifacts/ack', request, accessToken, 204)
  }

  static async cancel(jobId: string, accessToken: string): Promise<void> {
    await ApiHttpClient.authorizedDelete(CloudImportApi.jobPath(jobId), accessToken, 204)
  }

  private static copyJob(response: CloudImportJob): CloudImportJob {
    const progress: CloudImportProgress = new CloudImportProgress(
      response.progress.current, response.progress.total)
    return new CloudImportJob(response.jobId, response.bankName, response.subject,
      response.pageStart, response.pageEnd, response.sourceSha256, response.sourceSize,
      response.partCount, CloudImportApi.status(response.status), progress, response.expiresAt, response.createdAt,
      response.updatedAt)
  }

  private static copyDraft(response: CloudImportDraft): CloudImportDraft {
    const questions: Array<CloudImportDraftQuestion> = new Array<CloudImportDraftQuestion>()
    for (let questionIndex: number = 0; questionIndex < response.questions.length; questionIndex++) {
      const source: CloudImportDraftQuestion = response.questions[questionIndex]
      const images: Array<CloudImportArtifact> = new Array<CloudImportArtifact>()
      for (let imageIndex: number = 0; imageIndex < source.images.length; imageIndex++) {
        const image: CloudImportArtifact = source.images[imageIndex]
        images.push(new CloudImportArtifact(image.artifactId, image.sha256, image.size,
          image.contentType))
      }
      questions.push(new CloudImportDraftQuestion(source.draftQuestionId, source.type,
        source.question, source.options, source.answer, source.analysis, source.pageStart,
        source.pageEnd, source.confidence, source.reviewRequired, images))
    }
    return new CloudImportDraft(response.jobId, CloudImportApi.status(response.status), response.bankName,
      response.subject, response.expiresAt, questions)
  }

  private static copyConfirmResult(response: ConfirmImportResult): ConfirmImportResult {
    const questions: Array<ConfirmImportQuestionResult> = new Array<ConfirmImportQuestionResult>()
    for (let questionIndex: number = 0; questionIndex < response.questions.length; questionIndex++) {
      const source: ConfirmImportQuestionResult = response.questions[questionIndex]
      const images: Array<ConfirmedImportArtifact> = new Array<ConfirmedImportArtifact>()
      for (let imageIndex: number = 0; imageIndex < source.images.length; imageIndex++) {
        const image: ConfirmedImportArtifact = source.images[imageIndex]
        images.push(new ConfirmedImportArtifact(image.artifactId, image.sha256, image.size))
      }
      questions.push(new ConfirmImportQuestionResult(source.draftQuestionId, source.questionId,
        images))
    }
    return new ConfirmImportResult(response.bankId, questions, response.expiresAt)
  }

  private static jobPath(jobId: string): string {
    return '/v1/imports/pdf/' + CloudImportApi.identifier(jobId)
  }

  private static status(value: CloudImportStatus): CloudImportStatus {
    if (value === CloudImportStatus.UPLOADING || value === CloudImportStatus.QUEUED ||
      value === CloudImportStatus.PROCESSING || value === CloudImportStatus.REVIEW ||
      value === CloudImportStatus.CONFIRMED || value === CloudImportStatus.FAILED ||
      value === CloudImportStatus.CANCELLED || value === CloudImportStatus.EXPIRED) {
      return value
    }
    throw new Error('Invalid cloud import status')
  }

  private static identifier(value: string): string {
    if (value.length === 0) {
      throw new Error('Invalid cloud import identifier')
    }
    return encodeURIComponent(value)
  }
}
