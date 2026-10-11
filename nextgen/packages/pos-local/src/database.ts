/**
 * CHEESYOS NEXTGEN POS LOCAL — DATABASE MANAGER
 * 
 * Manages SQLite database connection lifecycle, WAL mode, foreign keys, and schema initialization.
 */

import { DatabaseSync } from 'node:sqlite';
import {
  OrderDomain,
  OrderItemDomain,
  PosKotDomain,
  KotItemDomain,
  KotCorrectionDomain,
  BillDomain,
  PaymentDomain,
} from '@cheesyos/nextgen-shared';
import { INITIAL_SCHEMA_SQL, SCHEMA_VERSION } from './schema.js';
import { IPosLocalDatabase, ISQLiteDatabase } from './adapter.js';
import { IPosPersistence, PullDataset, LocalDeviceConfigInput } from './persistence.js';
import { LocalDeviceConfig, getDeviceConfig, setLocalDeviceConfig } from './device.js';
import {
  OutboxRow,
  SyncCursor,
  getPendingOutboxEntries,
  acknowledgeOutboxRecord,
  updateOutboxRecordFailure,
  getSyncCursor,
} from './outbox.js';
import {
  SaveOrderResult,
  SaveKotResult,
  SaveBillWithSequenceResult,
  SavePaymentResult,
  SaveInventoryMovementInput,
  SaveInventoryMovementResult,
  saveOrderTransaction,
  saveKotDispatchTransaction,
  saveKotCorrectionTransaction,
  saveBillWithSequenceTransaction,
  savePaymentTransaction,
  saveInventoryMovementTransaction,
} from './transactions.js';
import { applyPullBatchLocal } from './pull-batch.js';

export class PosLocalDatabase implements IPosLocalDatabase, IPosPersistence {
  private db: DatabaseSync;
  private dbPath: string;
  private isTransactionActive: boolean = false;

  constructor(dbPath: string = ':memory:') {
    this.dbPath = dbPath;
    this.db = new DatabaseSync(dbPath);
    this.initialize();
  }

  public getRawDb(): ISQLiteDatabase {
    return this.db;
  }

  public getPath(): string {
    return this.dbPath;
  }

  public close(): void {
    this.db.close();
  }

  public getSchemaVersion(): number {
    const result = this.db.prepare('PRAGMA user_version').get() as { user_version: number } | undefined;
    return result?.user_version ?? 0;
  }

  private initialize(): void {
    // 1. Enable WAL mode (for file-based DBs) and Foreign Keys
    if (this.dbPath !== ':memory:') {
      this.db.exec('PRAGMA journal_mode = WAL;');
    }
    this.db.exec('PRAGMA foreign_keys = ON;');

    // 2. Check schema version
    const currentVersion = this.getSchemaVersion();
    if (currentVersion === 0) {
      this.db.exec(INITIAL_SCHEMA_SQL);
      this.db.exec(`PRAGMA user_version = ${SCHEMA_VERSION};`);
    } else if (currentVersion < SCHEMA_VERSION) {
      this.migrate(currentVersion, SCHEMA_VERSION);
    } else if (currentVersion > SCHEMA_VERSION) {
      throw new Error(
        `[PosLocalDatabase] Cannot open database with newer schema version (${currentVersion}) than current application supported version (${SCHEMA_VERSION})`
      );
    }
  }

  private migrate(fromVersion: number, toVersion: number): void {
    if (fromVersion < 2) {
      this.db.exec(`
        CREATE TABLE IF NOT EXISTS pos_device_config (
          device_id TEXT PRIMARY KEY,
          terminal_code TEXT NOT NULL UNIQUE,
          device_name TEXT NOT NULL,
          created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS pos_sequences (
          sequence_name TEXT PRIMARY KEY,
          current_value INTEGER NOT NULL DEFAULT 0,
          updated_at TEXT NOT NULL
        );

        PRAGMA user_version = 2;
      `);
    }
  }


  /**
   * Helper to execute a callback within a synchronous SQLite transaction.
   * Rejects nested transactions to prevent partial commit bugs.
   * Automatically issues COMMIT on success or ROLLBACK on exception.
   */
  public runTransaction<T>(fn: (db: ISQLiteDatabase) => T): T {
    if (this.isTransactionActive) {
      throw new Error('[PosLocalDatabase] Nested transactions are not supported. Wrap all atomic operations in a single top-level runTransaction block.');
    }

    this.isTransactionActive = true;
    this.db.exec('BEGIN IMMEDIATE;');
    try {
      const result = fn(this.db);
      this.db.exec('COMMIT;');
      this.isTransactionActive = false;
      return result;
    } catch (error) {
      try {
        this.db.exec('ROLLBACK;');
      } catch {
        // Ignore rollback failure if transaction was already aborted by SQLite
      }
      this.isTransactionActive = false;
      throw error;
    }
  }

  // --- IPosPersistence Implementation ---

  public async getDeviceConfig(): Promise<LocalDeviceConfig | null> {
    return getDeviceConfig(this.db);
  }

  public async setDeviceConfig(config: LocalDeviceConfigInput): Promise<LocalDeviceConfig> {
    return setLocalDeviceConfig(this.db, config);
  }

  public async saveOrderAggregate(order: OrderDomain, items: OrderItemDomain[]): Promise<SaveOrderResult> {
    return saveOrderTransaction(this, order, items);
  }

  public async saveKotAggregate(kot: PosKotDomain, items: KotItemDomain[]): Promise<SaveKotResult> {
    return saveKotDispatchTransaction(this, kot, items);
  }

  public async saveKotCorrection(correction: KotCorrectionDomain): Promise<OutboxRow> {
    return saveKotCorrectionTransaction(this, correction);
  }

  public async saveBillWithSequence(bill: BillDomain): Promise<SaveBillWithSequenceResult> {
    return saveBillWithSequenceTransaction(this, bill);
  }

  public async savePayment(payment: PaymentDomain, updatedBill: BillDomain): Promise<SavePaymentResult> {
    return savePaymentTransaction(this, payment, updatedBill);
  }

  public async saveInventoryMovement(input: SaveInventoryMovementInput): Promise<SaveInventoryMovementResult> {
    return saveInventoryMovementTransaction(this, input);
  }

  public async getPendingOutbox(limit: number = 10): Promise<OutboxRow[]> {
    return getPendingOutboxEntries(this.db, limit);
  }

  public async acknowledgeOutbox(seq: number): Promise<void> {
    this.runTransaction((db) => {
      acknowledgeOutboxRecord(db, seq);
    });
  }

  public async updateOutboxFailure(seq: number, error: string, nextAttemptAt?: string | null): Promise<void> {
    this.runTransaction((db) => {
      updateOutboxRecordFailure(db, seq, error, nextAttemptAt ?? null);
    });
  }

  public async getSyncCursor(dataset: PullDataset): Promise<SyncCursor> {
    return getSyncCursor(this.db, dataset);
  }

  public async applyPullBatch(
    dataset: PullDataset,
    rows: unknown[],
    newCursor: { lastUpdatedAt: string; lastId: string }
  ): Promise<number> {
    return this.runTransaction((db) => {
      return applyPullBatchLocal(db, dataset, rows as any[], newCursor);
    });
  }
}
