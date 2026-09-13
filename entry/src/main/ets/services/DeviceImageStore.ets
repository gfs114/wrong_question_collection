import { Context } from '@kit.AbilityKit'
import { relationalStore } from '@kit.ArkData'
import { DeviceQuestionImage } from '../models/CloudCacheModels'
import { DatabaseService } from './DatabaseService'

const DEVICE_IMAGE_TRANSACTION_OPTIONS: relationalStore.TransactionOptions = {
  transactionType: relationalStore.TransactionType.IMMEDIATE
}

export enum DeviceImageWriteOutcome {
  ROLLED_BACK = 'rolled_back',
  UNKNOWN = 'unknown'
}

export class DeviceImageStoreError extends Error {
  readonly outcome: DeviceImageWriteOutcome
  readonly primaryMessage: string
  readonly rollbackMessage: string

  constructor(outcome: DeviceImageWriteOutcome, primaryError: Error,
    rollbackError: Error | null = null) {
    const rollbackMessage: string = rollbackError === null ? '' : rollbackError.message
    super(rollbackError === null ? primaryError.message :
      primaryError.message + '; rollback also failed: ' + rollbackMessage)
    this.name = 'DeviceImageStoreError'
    this.outcome = outcome
    this.primaryMessage = primaryError.message
    this.rollbackMessage = rollbackMessage
  }
}

export class DeviceImageScope {
  static key(accountId: string, questionUuid: string): string {
    DeviceImageScope.validateIdentifier(accountId, 'Account ID')
    DeviceImageScope.validateIdentifier(questionUuid, 'Question UUID')
    return DeviceImageScope.accountHash(accountId) + ':' + questionUuid
  }

  static accountDirectory(filesDir: string, accountId: string): string {
    DeviceImageScope.validateIdentifier(filesDir, 'Files directory')
    DeviceImageScope.validateIdentifier(accountId, 'Account ID')
    let root: string = filesDir
    while (root.endsWith('/')) {
      root = root.substring(0, root.length - 1)
    }
    return root + '/question_images/' + DeviceImageScope.accountHash(accountId)
  }

  static accountHash(accountId: string): string {
    DeviceImageScope.validateIdentifier(accountId, 'Account ID')
    let encoded: string = ''
    for (let index: number = 0; index < accountId.length; index++) {
      let part: string = accountId.charCodeAt(index).toString(16)
      while (part.length < 4) {
        part = '0' + part
      }
      encoded += part
    }
    return encoded
  }

  static validateOwnedPath(filesDir: string, accountId: string, imagePath: string): void {
    const accountRoot: string = DeviceImageScope.accountDirectory(filesDir, accountId)
    if (!DeviceImageScope.isDirectDescendant(accountRoot, imagePath)) {
      throw new Error('Device image path is outside the current account directory')
    }
  }

  private static isDirectDescendant(accountRoot: string, imagePath: string): boolean {
    if (imagePath.indexOf('\\') >= 0 || imagePath.indexOf('\0') >= 0 ||
      !imagePath.startsWith(accountRoot + '/')) {
      return false
    }
    const relativePath: string = imagePath.substring(accountRoot.length + 1)
    if (relativePath.length === 0) {
      return false
    }
    const parts: Array<string> = relativePath.split('/')
    if (parts.length !== 1) {
      return false
    }
    for (let index: number = 0; index < parts.length; index++) {
      if (parts[index].length === 0 || parts[index] === '.' || parts[index] === '..') {
        return false
      }
    }
    return true
  }

  private static validateIdentifier(value: string, name: string): void {
    if (value.trim().length === 0) {
      throw new Error(name + ' cannot be empty')
    }
  }
}

export class DeviceImageStore {
  static async save(context: Context, image: DeviceQuestionImage): Promise<void> {
    return DeviceImageStore.saveBatch(context, [image])
  }

  static async saveBatch(context: Context, images: Array<DeviceQuestionImage>): Promise<void> {
    if (images.length === 0) {
      return
    }
    const filesDir: string = context.filesDir
    const snapshotImages: Array<DeviceQuestionImage> = new Array<DeviceQuestionImage>()
    const keys: Set<string> = new Set<string>()
    for (let index: number = 0; index < images.length; index++) {
      const image: DeviceQuestionImage = images[index]
      DeviceImageScope.key(image.accountId, image.questionUuid)
      DeviceImageScope.validateOwnedPath(filesDir, image.accountId, image.imagePath)
      if (!/^[a-f0-9]{64}$/.test(image.sha256) || !Number.isInteger(image.sortOrder) ||
        image.sortOrder < 0) {
        throw new Error('Device image metadata is invalid')
      }
      const key: string = image.accountId + ':' + image.questionUuid + ':' + image.sortOrder.toString()
      if (keys.has(key)) {
        throw new Error('Device image batch contains a duplicate key')
      }
      keys.add(key)
      snapshotImages.push(new DeviceQuestionImage(image.accountId, image.questionUuid,
        image.imagePath, image.sha256, image.sortOrder))
    }
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const transaction: relationalStore.Transaction =
      await store.createTransaction(DEVICE_IMAGE_TRANSACTION_OPTIONS)
    try {
      for (let index: number = 0; index < snapshotImages.length; index++) {
        const image: DeviceQuestionImage = snapshotImages[index]
        const values: Array<relationalStore.ValueType> = [
          image.accountId, image.questionUuid, image.imagePath, image.sha256, image.sortOrder
        ]
        await transaction.execute(
          'INSERT INTO device_question_image(account_id, question_uuid, image_path, sha256, sort_order) ' +
          'VALUES (?, ?, ?, ?, ?) ON CONFLICT(account_id, question_uuid, sort_order) DO UPDATE SET ' +
          'image_path = excluded.image_path, sha256 = excluded.sha256', values)
      }
      await transaction.commit()
    } catch (err) {
      const primaryError: Error = err instanceof Error ? err : new Error('Device image batch save failed')
      let rollbackError: Error | null = null
      try {
        await transaction.rollback()
      } catch (err) {
        rollbackError = err instanceof Error ? err : new Error('Device image transaction rollback failed')
      }
      if (rollbackError !== null) {
        throw new DeviceImageStoreError(DeviceImageWriteOutcome.UNKNOWN,
          primaryError, rollbackError)
      }
      throw new DeviceImageStoreError(DeviceImageWriteOutcome.ROLLED_BACK, primaryError)
    }
  }

  static async images(accountId: string, questionUuid: string): Promise<Array<DeviceQuestionImage>> {
    DeviceImageScope.key(accountId, questionUuid)
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const args: Array<relationalStore.ValueType> = [accountId, questionUuid]
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT account_id, question_uuid, image_path, sha256, sort_order ' +
      'FROM device_question_image WHERE account_id = ? AND question_uuid = ? ' +
      'ORDER BY sort_order ASC, image_path ASC', args)
    const images: Array<DeviceQuestionImage> = new Array<DeviceQuestionImage>()
    try {
      while (resultSet.goToNextRow()) {
        images.push(new DeviceQuestionImage(
          resultSet.getString(0), resultSet.getString(1), resultSet.getString(2),
          resultSet.getString(3), resultSet.getLong(4)))
      }
      return images
    } finally {
      resultSet.close()
    }
  }
}
