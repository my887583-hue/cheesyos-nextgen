/**
 * CHEESYOS NEXTGEN POS LOCAL — DURABLE OUTBOX CONTRACT & HELPERS
 * 
 * Manages atomic outbox queue inserts and pending entry queries.
 */

import type { DatabaseSync } from 'node:sqlite';
import { ISQLiteDatabase, IPosLocalDatabase } from './adapter.js';

export interface OutboxEntryInput {
  id?: string; // UUID string (generated if omitted)
  entityType: 'orders' | 'order_items' | 'pos_kots' | 'kot_items' | 'kot_corrections' | 'bills' | 'payments' | 'inventory_movements' | 'customers' | 'table_sessions';
  entityId: string;
  operation: 'INSERT' | 'UPDATE';
  payload: Record<string, unknown>;
  createdAt?: string;
}

export interface OutboxRow {
  seq: number;
  id: string;
  entity_type: string;
  entity_id: string;
  operation: 'INSERT' | 'UPDATE';
  payload_json: string;
  created_at: string;
  attempt_count: number;
  next_attempt_at: string | null;
  last_error: string | null;
}

function extractRawDb(dbInput: ISQLiteDatabase | IPosLocalDatabase | DatabaseSync): ISQLiteDatabase {
  if ('getRawDb' in dbInput && typeof (dbInput as any).getRawDb === 'function') {
    return (dbInput as IPosLocalDatabase).getRawDb();
  }
  return dbInput as ISQLiteDatabase;
}

/**
 * Inserts an outbox queue record inside an existing SQLite transaction.
 */
export function insertOutboxRecord(dbInput: ISQLiteDatabase | IPosLocalDatabase | DatabaseSync, input: OutboxEntryInput): OutboxRow {
  const db = extractRawDb(dbInput);
  const outboxId = input.id || crypto.randomUUID();
  const createdAt = input.createdAt || new Date().toISOString();
  const payloadJson = JSON.stringify(input.payload);

  const stmt = db.prepare(`
    INSERT INTO sync_outbox (
      id, entity_type, entity_id, operation, payload_json, created_at, attempt_count
    ) VALUES (
      ?, ?, ?, ?, ?, ?, 0
    )
  `);

  stmt.run(
    outboxId,
    input.entityType,
    input.entityId,
    input.operation,
    payloadJson,
    createdAt
  );

  return {
    seq: 0, // Assigned by AUTOINCREMENT in DB
    id: outboxId,
    entity_type: input.entityType,
    entity_id: input.entityId,
    operation: input.operation,
    payload_json: payloadJson,
    created_at: createdAt,
    attempt_count: 0,
    next_attempt_at: null,
    last_error: null,
  };
}

/**
 * Retrieves pending outbox entries ordered by sequence for cloud sync.
 */
export function getPendingOutboxEntries(dbInput: ISQLiteDatabase | IPosLocalDatabase | DatabaseSync, limit: number = 50): OutboxRow[] {
  const db = extractRawDb(dbInput);
  const stmt = db.prepare(`
    SELECT seq, id, entity_type, entity_id, operation, payload_json, created_at, attempt_count, next_attempt_at, last_error
    FROM sync_outbox
    ORDER BY seq ASC
    LIMIT ?
  `);
  return stmt.all(limit) as unknown as OutboxRow[];
}

/**
 * Deletes acknowledged outbox record by sequence number upon cloud push confirmation.
 */
export function acknowledgeOutboxRecord(dbInput: ISQLiteDatabase | IPosLocalDatabase | DatabaseSync, seq: number): void {
  const db = extractRawDb(dbInput);
  const stmt = db.prepare('DELETE FROM sync_outbox WHERE seq = ?');
  stmt.run(seq);
}

/**
 * Updates failure metadata for an outbox entry.
 */
export function updateOutboxRecordFailure(dbInput: ISQLiteDatabase | IPosLocalDatabase | DatabaseSync, seq: number, lastError: string, nextAttemptAt: string | null = null): void {
  const db = extractRawDb(dbInput);
  const stmt = db.prepare(`
    UPDATE sync_outbox
    SET attempt_count = attempt_count + 1,
        last_error = ?,
        next_attempt_at = ?
    WHERE seq = ?
  `);
  stmt.run(lastError, nextAttemptAt, seq);
}

export interface SyncCursor {
  dataset: string;
  lastUpdatedAt: string;
  lastId: string;
  updatedAt: string;
}

/**
 * Checks if a given entity ID has any pending outbox records.
 */
export function hasPendingOutboxRecord(dbInput: ISQLiteDatabase | IPosLocalDatabase | DatabaseSync, entityId: string): boolean {
  const db = extractRawDb(dbInput);
  const stmt = db.prepare(`
    SELECT 1 FROM sync_outbox 
    WHERE entity_id = ? 
       OR json_extract(payload_json, '$.kot.order_id') = ?
       OR json_extract(payload_json, '$.order.id') = ?
       OR json_extract(payload_json, '$.correction.order_id') = ?
       OR json_extract(payload_json, '$.updatedOrderItem.id') = ?
    LIMIT 1
  `);
  const row = stmt.get(entityId, entityId, entityId, entityId, entityId);
  return !!row;
}

/**
 * Gets persisted cursor for a dataset from local SQLite.
 */
export function getSyncCursor(dbInput: ISQLiteDatabase | IPosLocalDatabase | DatabaseSync, dataset: string): SyncCursor {
  const db = extractRawDb(dbInput);
  const stmt = db.prepare('SELECT dataset, last_updated_at, last_id, updated_at FROM sync_cursors WHERE dataset = ?');
  const row = stmt.get(dataset) as { dataset: string; last_updated_at: string; last_id: string; updated_at: string } | undefined;
  if (!row) {
    return {
      dataset,
      lastUpdatedAt: '1970-01-01T00:00:00.000Z',
      lastId: '00000000-0000-0000-0000-000000000000',
      updatedAt: '1970-01-01T00:00:00.000Z',
    };
  }
  return {
    dataset: row.dataset,
    lastUpdatedAt: row.last_updated_at,
    lastId: row.last_id,
    updatedAt: row.updated_at,
  };
}

/**
 * Updates persisted cursor for a dataset inside a SQLite transaction.
 */
export function setSyncCursor(dbInput: ISQLiteDatabase | IPosLocalDatabase | DatabaseSync, dataset: string, lastUpdatedAt: string, lastId: string): void {
  const db = extractRawDb(dbInput);
  const now = new Date().toISOString();
  const stmt = db.prepare(`
    INSERT INTO sync_cursors (dataset, last_updated_at, last_id, updated_at)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(dataset) DO UPDATE SET
      last_updated_at = excluded.last_updated_at,
      last_id = excluded.last_id,
      updated_at = excluded.updated_at
  `);
  stmt.run(dataset, lastUpdatedAt, lastId, now);
}
