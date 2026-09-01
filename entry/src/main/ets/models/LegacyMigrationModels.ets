/**
 * Strict ArkTS types for the legacy cloud text migration (Task 13).
 *
 * The migration claims the current Huawei account explicitly, uploads the
 * legacy non-sample banks one at a time with their stable sync UUIDs, pulls
 * the authoritative server snapshot, verifies counts and normalized text
 * digests, and only then updates the cloud cache and rebinds device images.
 */
export class LegacyMigrationStage {
  static readonly UNCLAIMED: string = 'unclaimed'
  static readonly UPLOADING: string = 'uploading'
  static readonly VERIFYING: string = 'verifying'
  static readonly COMPLETED: string = 'completed'
  static readonly FAILED: string = 'failed'
}

export class LegacyMigrationErrors {
  static readonly SIGNED_OUT: string = 'SIGNED_OUT'
  static readonly ACCOUNT_MISMATCH: string = 'ACCOUNT_MISMATCH'
  static readonly UPLOAD_FAILED: string = 'UPLOAD_FAILED'
  static readonly SNAPSHOT_FAILED: string = 'SNAPSHOT_FAILED'
  static readonly COUNT_MISMATCH: string = 'COUNT_MISMATCH'
  static readonly DIGEST_MISMATCH: string = 'DIGEST_MISMATCH'
  static readonly CACHE_WRITE_FAILED: string = 'CACHE_WRITE_FAILED'
  static readonly IMAGE_REBIND_FAILED: string = 'IMAGE_REBIND_FAILED'
}

/**
 * Pure policy: an unclaimed migration may be claimed by the current account,
 * an already-claimed migration only by the same account. Legacy retirement
 * (Task 14) requires the server acknowledgement, the cache verification and
 * the image mapping commitment to all be complete; Task 13 itself never
 * deletes the legacy tables.
 */
export class MigrationPolicy {
  static canClaim(existingAccountId: string, currentAccountId: string): boolean {
    if (existingAccountId.trim().length === 0) {
      return true
    }
    return existingAccountId === currentAccountId
  }

  static canRetireLegacy(serverAcknowledged: boolean, cacheVerified: boolean,
    imageMappingsCommitted: boolean): boolean {
    return serverAcknowledged && cacheVerified && imageMappingsCommitted
  }
}

export class LegacyCanonicalQuestion {
  uuid: string
  type: string
  content: string
  options: Array<string>
  answer: string
  analysis: string

  constructor(uuid: string, type: string, content: string, options: Array<string>,
    answer: string, analysis: string) {
    this.uuid = uuid
    this.type = type
    this.content = content
    this.options = options.slice()
    this.answer = answer
    this.analysis = analysis
  }
}

/**
 * Deterministic normalization shared by the local legacy text and the server
 * snapshot. Rules:
 * - questions are ordered by their server UUID ascending, never by input
 *   order or object property enumeration order;
 * - bank name, subject and question text are trimmed exactly like the server
 *   store (which trims these fields when materializing);
 * - type, options, answer and analysis are kept verbatim because the server
 *   stores them untrimmed;
 * - options are serialized in numeric index order as a JSON array of
 *   "index=value" lines;
 * - fields are joined with '\n' in a fixed field order.
 */
export class LegacyTextNormalizer {
  static canonicalText(bankName: string, subject: string,
    questions: Array<LegacyCanonicalQuestion>): string {
    const ordered: Array<LegacyCanonicalQuestion> = questions.slice()
    ordered.sort((left: LegacyCanonicalQuestion, right: LegacyCanonicalQuestion): number => {
      if (left.uuid < right.uuid) {
        return -1
      }
      if (left.uuid > right.uuid) {
        return 1
      }
      return 0
    })
    const blocks: Array<string> = new Array<string>()
    blocks.push('name=' + bankName.trim())
    blocks.push('subject=' + subject.trim())
    for (let index: number = 0; index < ordered.length; index++) {
      blocks.push(LegacyTextNormalizer.questionBlock(ordered[index]))
    }
    return blocks.join('\n')
  }

  static questionBlock(question: LegacyCanonicalQuestion): string {
    const lines: Array<string> = new Array<string>()
    lines.push('type=' + question.type)
    lines.push('question=' + question.content.trim())
    const optionLines: Array<string> = new Array<string>()
    for (let index: number = 0; index < question.options.length; index++) {
      optionLines.push(index.toString() + '=' + question.options[index])
    }
    lines.push('options=' + JSON.stringify(optionLines))
    lines.push('answer=' + question.answer)
    lines.push('analysis=' + question.analysis)
    return lines.join('\n')
  }
}

export class LegacyMigrationState {
  accountId: string
  stage: string
  bankIds: Array<string>
  currentBankId: string
  acknowledgedBankIds: Array<string>
  verifiedBankIds: Array<string>
  reboundBankIds: Array<string>
  totalBanks: number
  totalQuestions: number
  totalImages: number
  errorCode: string
  errorMessage: string
  updateTime: number

  constructor(accountId: string, stage: string, bankIds: Array<string>, currentBankId: string,
    acknowledgedBankIds: Array<string>, verifiedBankIds: Array<string>,
    reboundBankIds: Array<string>, totalBanks: number, totalQuestions: number, totalImages: number,
    errorCode: string, errorMessage: string, updateTime: number) {
    this.accountId = accountId
    this.stage = stage
    this.bankIds = bankIds.slice()
    this.currentBankId = currentBankId
    this.acknowledgedBankIds = acknowledgedBankIds.slice()
    this.verifiedBankIds = verifiedBankIds.slice()
    this.reboundBankIds = reboundBankIds.slice()
    this.totalBanks = totalBanks
    this.totalQuestions = totalQuestions
    this.totalImages = totalImages
    this.errorCode = errorCode
    this.errorMessage = errorMessage
    this.updateTime = updateTime
  }

  processedBanks(): number {
    return this.reboundBankIds.length
  }

  serverAcknowledged(): boolean {
    return this.totalBanks > 0 && this.acknowledgedBankIds.length === this.totalBanks
  }

  cacheVerified(): boolean {
    return this.totalBanks > 0 && this.verifiedBankIds.length === this.totalBanks
  }

  imageMappingsCommitted(): boolean {
    return this.totalBanks > 0 && this.reboundBankIds.length === this.totalBanks
  }

  canRetry(): boolean {
    return this.stage === LegacyMigrationStage.UPLOADING ||
      this.stage === LegacyMigrationStage.VERIFYING ||
      this.stage === LegacyMigrationStage.FAILED
  }
}
