/**
 * CHEESYOS NEXTGEN POS LOCAL — DEVICE IDENTITY & OFFLINE BILL NUMBERING
 * 
 * Provides local terminal identity persistence, atomic sequence allocation,
 * and display bill number formatting (e.g. CB-T01-000001).
 */

import type { DatabaseSync } from 'node:sqlite';
import { ISQLiteDatabase, IPosLocalDatabase } from './adapter.js';
import { PosLocalDatabase } from './database.js';

export interface LocalDeviceConfig {
  device_id: string;
  terminal_code: string;
  device_name: string;
  created_at: string;
}

export interface BillNumberAllocation {
  billNumber: string;
  sequenceNumber: number;
  terminalCode: string;
  deviceId: string;
}

function extractRawDb(dbInput: ISQLiteDatabase | IPosLocalDatabase | DatabaseSync | PosLocalDatabase): ISQLiteDatabase {
  if ('getRawDb' in dbInput && typeof (dbInput as any).getRawDb === 'function') {
    return (dbInput as IPosLocalDatabase).getRawDb();
  }
  return dbInput as ISQLiteDatabase;
}

/**
 * Stores or updates local terminal identity in SQLite pos_device_config.
 * Replaces any existing single local device config row.
 */
export function setLocalDeviceConfig(
  dbInput: ISQLiteDatabase | IPosLocalDatabase | DatabaseSync | PosLocalDatabase,
  config: { device_id: string; terminal_code: string; device_name: string; created_at?: string }
): LocalDeviceConfig {
  const db = extractRawDb(dbInput);

  const normalizedTerminalCode = config.terminal_code.trim().toUpperCase();
  if (!normalizedTerminalCode || normalizedTerminalCode.length < 2 || !/^[A-Z0-9_-]+$/.test(normalizedTerminalCode)) {
    throw new Error(`[PosDevice] Invalid terminal_code: "${config.terminal_code}". Must be at least 2 alphanumeric characters.`);
  }

  const deviceId = config.device_id.trim();
  if (!deviceId) {
    throw new Error('[PosDevice] device_id must be a valid non-empty string UUID.');
  }

  const deviceName = config.device_name.trim();
  if (!deviceName) {
    throw new Error('[PosDevice] device_name cannot be empty.');
  }

  const createdAt = config.created_at || new Date().toISOString();

  // Clear any existing config row to preserve single-terminal identity invariant
  db.exec('DELETE FROM pos_device_config;');

  const stmt = db.prepare(`
    INSERT INTO pos_device_config (device_id, terminal_code, device_name, created_at)
    VALUES (?, ?, ?, ?)
  `);

  stmt.run(deviceId, normalizedTerminalCode, deviceName, createdAt);

  return {
    device_id: deviceId,
    terminal_code: normalizedTerminalCode,
    device_name: deviceName,
    created_at: createdAt,
  };
}

/**
 * Retrieves configured local terminal identity, or null if unconfigured.
 */
export function getDeviceConfig(dbInput: ISQLiteDatabase | IPosLocalDatabase | DatabaseSync | PosLocalDatabase): LocalDeviceConfig | null {
  const db = extractRawDb(dbInput);
  const stmt = db.prepare(`
    SELECT device_id, terminal_code, device_name, created_at
    FROM pos_device_config
    LIMIT 1
  `);
  const row = stmt.get() as LocalDeviceConfig | undefined;
  return row ?? null;
}

/**
 * Atomically increments and returns the next integer sequence for a named sequence.
 * Must be executed within an active SQLite transaction.
 */
export function allocateNextSequence(
  dbInput: ISQLiteDatabase | IPosLocalDatabase | DatabaseSync | PosLocalDatabase,
  sequenceName: string = 'bill_sequence'
): number {
  const db = extractRawDb(dbInput);
  const now = new Date().toISOString();

  const selectStmt = db.prepare(`SELECT current_value FROM pos_sequences WHERE sequence_name = ?`);
  const existing = selectStmt.get(sequenceName) as { current_value: number } | undefined;

  if (!existing) {
    const insertStmt = db.prepare(`
      INSERT INTO pos_sequences (sequence_name, current_value, updated_at)
      VALUES (?, 1, ?)
    `);
    insertStmt.run(sequenceName, now);
    return 1;
  }

  const nextVal = existing.current_value + 1;
  const updateStmt = db.prepare(`
    UPDATE pos_sequences
    SET current_value = ?, updated_at = ?
    WHERE sequence_name = ?
  `);
  updateStmt.run(nextVal, now, sequenceName);

  return nextVal;
}

/**
 * Formats terminal code and local integer sequence into readable bill display string.
 * Example: formatBillNumber('T01', 1) => 'CB-T01-000001'
 */
export function formatBillNumber(terminalCode: string, sequenceNumber: number): string {
  const code = terminalCode.trim().toUpperCase();
  const seqStr = String(sequenceNumber).padStart(6, '0');
  return `CB-${code}-${seqStr}`;
}

/**
 * Atomically allocates next bill sequence and returns formatted bill display number.
 * Must be executed within a SQLite transaction.
 */
export function allocateNextBillNumber(
  dbInput: ISQLiteDatabase | IPosLocalDatabase | DatabaseSync | PosLocalDatabase
): BillNumberAllocation {
  const db = extractRawDb(dbInput);

  const config = getDeviceConfig(db);
  if (!config) {
    throw new Error('[PosDevice] Terminal device identity is not configured locally. Bill allocation rejected.');
  }

  const sequenceNumber = allocateNextSequence(db, 'bill_sequence');
  const billNumber = formatBillNumber(config.terminal_code, sequenceNumber);

  return {
    billNumber,
    sequenceNumber,
    terminalCode: config.terminal_code,
    deviceId: config.device_id,
  };
}
