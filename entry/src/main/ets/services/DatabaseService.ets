import { Context } from '@kit.AbilityKit'
import { relationalStore } from '@kit.ArkData'

const STORE_CONFIG: relationalStore.StoreConfig = {
  name: 'wrong_question_collection.db',
  securityLevel: relationalStore.SecurityLevel.S1
}
const SCHEMA_VERSION: number = 5
const SCHEMA_TRANSACTION_OPTIONS: relationalStore.TransactionOptions = {
  transactionType: relationalStore.TransactionType.IMMEDIATE
}

const CREATE_QUESTION_BANK: string = 'CREATE TABLE IF NOT EXISTS question_bank (' +
  'id TEXT PRIMARY KEY, ' +
  'bank_name TEXT NOT NULL, ' +
  'subject TEXT NOT NULL, ' +
  'question_count INTEGER NOT NULL, ' +
  'create_time INTEGER NOT NULL, ' +
  'is_sample INTEGER NOT NULL DEFAULT 0)'

const CREATE_QUESTION: string = 'CREATE TABLE IF NOT EXISTS question (' +
  'id TEXT PRIMARY KEY, ' +
  'bank_id TEXT NOT NULL, ' +
  'type TEXT NOT NULL, ' +
  'content TEXT NOT NULL, ' +
  'options_json TEXT NOT NULL, ' +
  'answer TEXT NOT NULL, ' +
  'analysis TEXT NOT NULL, ' +
  'source_page_start INTEGER NOT NULL DEFAULT 0, ' +
  'source_page_end INTEGER NOT NULL DEFAULT 0, ' +
  "review_state TEXT NOT NULL DEFAULT 'confirmed')"

const CREATE_QUESTION_IMAGE: string = 'CREATE TABLE IF NOT EXISTS question_image (' +
  'id TEXT PRIMARY KEY, ' +
  'question_id TEXT NOT NULL, ' +
  'page_number INTEGER NOT NULL, ' +
  'image_path TEXT NOT NULL, ' +
  'sort_order INTEGER NOT NULL)'

const CREATE_QUESTION_IMAGE_INDEX: string =
  'CREATE INDEX IF NOT EXISTS idx_question_image_question_id ON question_image(question_id)'

const CREATE_QUESTION_IMAGE_CLEANUP_DEBT: string =
  'CREATE TABLE IF NOT EXISTS question_image_cleanup_debt (' +
  'path TEXT PRIMARY KEY, ' +
  'create_time INTEGER NOT NULL)'

const CREATE_QUESTION_IMAGE_ROLLBACK_DEBT: string =
  'CREATE TABLE IF NOT EXISTS question_image_rollback_debt (' +
  'final_path TEXT PRIMARY KEY, ' +
  'cache_path TEXT NOT NULL, ' +
  'bank_id TEXT NOT NULL, ' +
  'create_time INTEGER NOT NULL)'

const CREATE_WRONG_QUESTION: string = 'CREATE TABLE IF NOT EXISTS wrong_question (' +
  'id TEXT PRIMARY KEY, ' +
  'question_id TEXT NOT NULL UNIQUE, ' +
  'bank_id TEXT NOT NULL, ' +
  'subject TEXT NOT NULL, ' +
  'add_time INTEGER NOT NULL, ' +
  'mastered INTEGER NOT NULL DEFAULT 0, ' +
  "user_answer TEXT NOT NULL DEFAULT '')"

const CREATE_SYNC_IDENTITY: string = 'CREATE TABLE IF NOT EXISTS sync_identity (' +
  'entity_type TEXT NOT NULL, ' +
  'local_id TEXT NOT NULL, ' +
  'client_uuid TEXT NOT NULL, ' +
  'PRIMARY KEY(entity_type, local_id), ' +
  'UNIQUE(entity_type, client_uuid))'

const CREATE_SYNC_OUTBOX: string = 'CREATE TABLE IF NOT EXISTS sync_outbox (' +
  'operation_id TEXT PRIMARY KEY, ' +
  'entity_type TEXT NOT NULL, ' +
  'entity_uuid TEXT NOT NULL, ' +
  'operation_type TEXT NOT NULL, ' +
  'payload_json TEXT NOT NULL, ' +
  'create_time INTEGER NOT NULL, ' +
  'UNIQUE(entity_type, entity_uuid))'

const CREATE_SYNC_STATE: string = 'CREATE TABLE IF NOT EXISTS sync_state (' +
  'user_id TEXT PRIMARY KEY, ' +
  "cursor TEXT NOT NULL DEFAULT '0', " +
  'update_time INTEGER NOT NULL)'

const CREATE_SYNC_OUTBOX_INDEX: string =
  'CREATE INDEX IF NOT EXISTS idx_sync_outbox_create_time ON sync_outbox(create_time)'

export class DatabaseService {
  private static store: relationalStore.RdbStore | null = null
  private static initialization: Promise<void> | null = null

  static async initialize(context: Context): Promise<void> {
    if (DatabaseService.store !== null) {
      return
    }
    if (DatabaseService.initialization !== null) {
      await DatabaseService.initialization
      return
    }
    const initialization: Promise<void> = DatabaseService.open(context)
    DatabaseService.initialization = initialization
    try {
      await initialization
    } finally {
      DatabaseService.initialization = null
    }
  }

  static getStore(): relationalStore.RdbStore {
    const store: relationalStore.RdbStore | null = DatabaseService.store
    if (store === null) {
      throw new Error('DatabaseService is not initialized')
    }
    return store
  }

  private static async open(context: Context): Promise<void> {
    const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, STORE_CONFIG)
    try {
      const version: number = store.version
      if (version > SCHEMA_VERSION) {
        throw new Error('Unsupported database schema version ' + version.toString())
      }
      if (version === 0) {
        await DatabaseService.createSchema(store)
        store.version = SCHEMA_VERSION
      } else if (version === 1) {
        await DatabaseService.migrateVersionOne(store)
        await DatabaseService.migrateVersionTwo(store)
        await DatabaseService.migrateVersionThree(store)
        await DatabaseService.migrateVersionFour(store)
        store.version = SCHEMA_VERSION
      } else if (version === 2) {
        await DatabaseService.migrateVersionTwo(store)
        await DatabaseService.migrateVersionThree(store)
        await DatabaseService.migrateVersionFour(store)
        store.version = SCHEMA_VERSION
      } else if (version === 3) {
        await DatabaseService.migrateVersionThree(store)
        await DatabaseService.migrateVersionFour(store)
        store.version = SCHEMA_VERSION
      } else if (version === 4) {
        await DatabaseService.migrateVersionFour(store)
        store.version = SCHEMA_VERSION
      }
      DatabaseService.store = store
    } catch (err) {
      try {
        await store.close()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to initialize database')
    }
  }

  private static async createSchema(store: relationalStore.RdbStore): Promise<void> {
    const transaction: relationalStore.Transaction = await store.createTransaction(SCHEMA_TRANSACTION_OPTIONS)
    try {
      await transaction.execute(CREATE_QUESTION_BANK)
      await transaction.execute(CREATE_QUESTION)
      await transaction.execute(CREATE_QUESTION_IMAGE)
      await transaction.execute(CREATE_QUESTION_IMAGE_CLEANUP_DEBT)
      await transaction.execute(CREATE_QUESTION_IMAGE_ROLLBACK_DEBT)
      await transaction.execute(CREATE_WRONG_QUESTION)
      await transaction.execute(CREATE_SYNC_IDENTITY)
      await transaction.execute(CREATE_SYNC_OUTBOX)
      await transaction.execute(CREATE_SYNC_STATE)
      await transaction.execute('CREATE INDEX IF NOT EXISTS idx_question_bank_id ON question(bank_id)')
      await transaction.execute(CREATE_QUESTION_IMAGE_INDEX)
      await transaction.execute('CREATE INDEX IF NOT EXISTS idx_wrong_question_bank_id ON wrong_question(bank_id)')
      await transaction.execute('CREATE INDEX IF NOT EXISTS idx_wrong_question_subject ON wrong_question(subject)')
      await transaction.execute('CREATE INDEX IF NOT EXISTS idx_wrong_question_mastered ON wrong_question(mastered)')
      await transaction.execute(CREATE_SYNC_OUTBOX_INDEX)
      await transaction.commit()
    } catch (err) {
      try {
        await transaction.rollback()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to create database schema')
    }
  }

  private static async migrateVersionOne(store: relationalStore.RdbStore): Promise<void> {
    const transaction: relationalStore.Transaction = await store.createTransaction(SCHEMA_TRANSACTION_OPTIONS)
    try {
      const columnsResultSet: relationalStore.ResultSet =
        await transaction.querySql('PRAGMA table_info(question)')
      let hasSourcePageStart: boolean = false
      let hasSourcePageEnd: boolean = false
      let hasReviewState: boolean = false
      try {
        while (columnsResultSet.goToNextRow()) {
          const columnName: string = columnsResultSet.getString(1)
          if (columnName === 'source_page_start') {
            hasSourcePageStart = true
          } else if (columnName === 'source_page_end') {
            hasSourcePageEnd = true
          } else if (columnName === 'review_state') {
            hasReviewState = true
          }
        }
      } finally {
        columnsResultSet.close()
      }
      if (!hasSourcePageStart) {
        await transaction.execute(
          'ALTER TABLE question ADD COLUMN source_page_start INTEGER NOT NULL DEFAULT 0')
      }
      if (!hasSourcePageEnd) {
        await transaction.execute(
          'ALTER TABLE question ADD COLUMN source_page_end INTEGER NOT NULL DEFAULT 0')
      }
      if (!hasReviewState) {
        await transaction.execute(
          "ALTER TABLE question ADD COLUMN review_state TEXT NOT NULL DEFAULT 'confirmed'")
      }
      await transaction.execute(CREATE_QUESTION_IMAGE)
      await transaction.execute(CREATE_QUESTION_IMAGE_INDEX)
      await transaction.commit()
    } catch (err) {
      try {
        await transaction.rollback()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to migrate database schema')
    }
  }

  private static async migrateVersionTwo(store: relationalStore.RdbStore): Promise<void> {
    const transaction: relationalStore.Transaction = await store.createTransaction(SCHEMA_TRANSACTION_OPTIONS)
    try {
      await transaction.execute(CREATE_QUESTION_IMAGE_CLEANUP_DEBT)
      await transaction.commit()
    } catch (err) {
      try {
        await transaction.rollback()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to migrate database schema')
    }
  }

  private static async migrateVersionThree(store: relationalStore.RdbStore): Promise<void> {
    const transaction: relationalStore.Transaction = await store.createTransaction(SCHEMA_TRANSACTION_OPTIONS)
    try {
      await transaction.execute(CREATE_QUESTION_IMAGE_ROLLBACK_DEBT)
      await transaction.commit()
    } catch (err) {
      try {
        await transaction.rollback()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to migrate database schema')
    }
  }

  private static async migrateVersionFour(store: relationalStore.RdbStore): Promise<void> {
    const transaction: relationalStore.Transaction = await store.createTransaction(SCHEMA_TRANSACTION_OPTIONS)
    try {
      await transaction.execute(CREATE_SYNC_IDENTITY)
      await transaction.execute(CREATE_SYNC_OUTBOX)
      await transaction.execute(CREATE_SYNC_STATE)
      await transaction.execute(CREATE_SYNC_OUTBOX_INDEX)
      await transaction.commit()
    } catch (err) {
      try {
        await transaction.rollback()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to migrate database schema')
    }
  }
}
