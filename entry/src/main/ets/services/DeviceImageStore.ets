import { Context } from '@kit.AbilityKit'
import { relationalStore } from '@kit.ArkData'
import { DeviceQuestionImage } from '../models/CloudCacheModels'
import { DatabaseService } from './DatabaseService'

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
    DeviceImageScope.key(image.accountId, image.questionUuid)
    DeviceImageScope.validateOwnedPath(context.filesDir, image.accountId, image.imagePath)
    if (!/^[a-f0-9]{64}$/.test(image.sha256)) {
      throw new Error('Device image SHA-256 is invalid')
    }
    if (!Number.isInteger(image.sortOrder) || image.sortOrder < 0) {
      throw new Error('Device image sort order is invalid')
    }
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const values: Array<relationalStore.ValueType> = [
      image.accountId, image.questionUuid, image.imagePath, image.sha256, image.sortOrder
    ]
    await store.execute(
      'INSERT INTO device_question_image(account_id, question_uuid, image_path, sha256, sort_order) ' +
      'VALUES (?, ?, ?, ?, ?) ON CONFLICT(account_id, question_uuid, sort_order) DO UPDATE SET ' +
      'image_path = excluded.image_path, sha256 = excluded.sha256', values)
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
