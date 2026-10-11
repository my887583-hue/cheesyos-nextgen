/**
 * CHEESYOS NEXTGEN POS LOCAL — DEVICE IDENTITY & OFFLINE BILL NUMBERING TEST SUITE
 * 
 * Verifies local terminal identity persistence, sequence allocation atomicity,
 * rollback safety, format consistency, and schema v1 to v2 migration.
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

import {
  PosLocalDatabase,
  setLocalDeviceConfig,
  getDeviceConfig,
  allocateNextSequence,
  formatBillNumber,
  allocateNextBillNumber,
  getPendingOutboxEntries,
} from '../src/index.js';

describe('Phase 3F.1 — Device Identity & Offline Bill Numbering', () => {
  test('1. DEVICE_CONFIG_PERSISTENCE — Saving device config persists across DB instance restarts', () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'cheesyos-device-test-'));
    const dbPath = path.join(tmpDir, 'test_device.db');

    try {
      // Step A: Initialize DB & Save Config
      const db1 = new PosLocalDatabase(dbPath);
      const testDeviceId = '11111111-1111-4111-8111-111111111111';
      setLocalDeviceConfig(db1, {
        device_id: testDeviceId,
        terminal_code: 't01',
        device_name: 'Main Counter POS',
      });
      db1.close();

      // Step B: Reopen DB & Verify Persistence
      const db2 = new PosLocalDatabase(dbPath);
      const config = getDeviceConfig(db2);
      assert.notEqual(config, null);
      assert.equal(config?.device_id, testDeviceId);
      assert.equal(config?.terminal_code, 'T01'); // Auto-normalized to UPPERCASE
      assert.equal(config?.device_name, 'Main Counter POS');
      db2.close();
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  test('2. TERMINAL_CODE_FORMAT — Validates and normalizes terminal_code format', () => {
    const db = new PosLocalDatabase(':memory:');

    // Reject empty or invalid codes
    assert.throws(() => {
      setLocalDeviceConfig(db, {
        device_id: '11111111-1111-4111-8111-111111111111',
        terminal_code: '',
        device_name: 'POS 1',
      });
    }, /Invalid terminal_code/);

    assert.throws(() => {
      setLocalDeviceConfig(db, {
        device_id: '11111111-1111-4111-8111-111111111111',
        terminal_code: 'A', // Too short (<2)
        device_name: 'POS 1',
      });
    }, /Invalid terminal_code/);

    // Normalize lowercase to uppercase
    const saved = setLocalDeviceConfig(db, {
      device_id: '11111111-1111-4111-8111-111111111111',
      terminal_code: 't-02_a',
      device_name: 'POS 2',
    });
    assert.equal(saved.terminal_code, 'T-02_A');

    db.close();
  });

  test('3. SEQUENCE_FIRST_VALUE — Allocating first sequence starts at 1', () => {
    const dbManager = new PosLocalDatabase(':memory:');
    dbManager.runTransaction((rawDb) => {
      const seq = allocateNextSequence(rawDb, 'bill_sequence');
      assert.equal(seq, 1);
    });
    dbManager.close();
  });

  test('4. SEQUENCE_INCREMENT — Sequential allocations increment monotonically', () => {
    const dbManager = new PosLocalDatabase(':memory:');
    dbManager.runTransaction((rawDb) => {
      assert.equal(allocateNextSequence(rawDb, 'bill_sequence'), 1);
      assert.equal(allocateNextSequence(rawDb, 'bill_sequence'), 2);
      assert.equal(allocateNextSequence(rawDb, 'bill_sequence'), 3);
    });
    dbManager.close();
  });

  test('5. SEQUENCE_RESTART_PERSISTENCE — Sequence value persists across DB restarts', () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'cheesyos-seq-test-'));
    const dbPath = path.join(tmpDir, 'test_seq.db');

    try {
      const db1 = new PosLocalDatabase(dbPath);
      db1.runTransaction((rawDb) => {
        allocateNextSequence(rawDb, 'bill_sequence');
        allocateNextSequence(rawDb, 'bill_sequence');
      });
      db1.close();

      const db2 = new PosLocalDatabase(dbPath);
      db2.runTransaction((rawDb) => {
        const seq = allocateNextSequence(rawDb, 'bill_sequence');
        assert.equal(seq, 3);
      });
      db2.close();
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  test('6. SEQUENCE_ROLLBACK — Sequence allocation rolls back if transaction throws error', () => {
    const dbManager = new PosLocalDatabase(':memory:');
    setLocalDeviceConfig(dbManager, {
      device_id: '11111111-1111-4111-8111-111111111111',
      terminal_code: 'T01',
      device_name: 'Main POS',
    });

    // Allocate seq 1 successfully
    dbManager.runTransaction((rawDb) => {
      allocateNextBillNumber(rawDb);
    });

    // Attempt allocation in a failing transaction
    assert.throws(() => {
      dbManager.runTransaction((rawDb) => {
        allocateNextBillNumber(rawDb); // allocates seq 2
        throw new Error('Simulated transaction failure (e.g. disk/validation error)');
      });
    }, /Simulated transaction failure/);

    // Next transaction must receive sequence 2 (since seq 2 was rolled back)
    dbManager.runTransaction((rawDb) => {
      const res = allocateNextBillNumber(rawDb);
      assert.equal(res.sequenceNumber, 2);
      assert.equal(res.billNumber, 'CB-T01-000002');
    });

    dbManager.close();
  });

  test('7. SEQUENCE_RAPID_ALLOCATION — Consecutive rapid allocations generate unique ordered sequences', () => {
    const dbManager = new PosLocalDatabase(':memory:');
    setLocalDeviceConfig(dbManager, {
      device_id: '11111111-1111-4111-8111-111111111111',
      terminal_code: 'T01',
      device_name: 'Main POS',
    });

    const allocatedNumbers: string[] = [];
    for (let i = 0; i < 50; i++) {
      dbManager.runTransaction((rawDb) => {
        const res = allocateNextBillNumber(rawDb);
        allocatedNumbers.push(res.billNumber);
      });
    }

    assert.equal(allocatedNumbers.length, 50);
    assert.equal(allocatedNumbers[0], 'CB-T01-000001');
    assert.equal(allocatedNumbers[49], 'CB-T01-000050');
    // Ensure 50 distinct numbers
    const unique = new Set(allocatedNumbers);
    assert.equal(unique.size, 50);

    dbManager.close();
  });

  test('8. BILL_NUMBER_FORMAT — Formats bill string according to CB-{TERMINAL_CODE}-{LOCAL_SEQUENCE}', () => {
    assert.equal(formatBillNumber('T01', 1), 'CB-T01-000001');
    assert.equal(formatBillNumber('T05', 1234), 'CB-T05-001234');
    assert.equal(formatBillNumber('pos-99', 999999), 'CB-POS-99-999999');
  });

  test('9. DEVICE_CONFIG_MISSING_REJECTED — allocateNextBillNumber throws if device is unconfigured', () => {
    const dbManager = new PosLocalDatabase(':memory:');
    assert.throws(() => {
      dbManager.runTransaction((rawDb) => {
        allocateNextBillNumber(rawDb);
      });
    }, /Terminal device identity is not configured locally/);
    dbManager.close();
  });

  test('10. NO_OUTBOX_SIDE_EFFECT_FROM_SEQUENCE_HELPER — Sequence allocation does not inject outbox rows by itself', () => {
    const dbManager = new PosLocalDatabase(':memory:');
    setLocalDeviceConfig(dbManager, {
      device_id: '11111111-1111-4111-8111-111111111111',
      terminal_code: 'T01',
      device_name: 'Main POS',
    });

    dbManager.runTransaction((rawDb) => {
      allocateNextBillNumber(rawDb);
    });

    const pending = getPendingOutboxEntries(dbManager.getRawDb());
    assert.equal(pending.length, 0);

    dbManager.close();
  });

  test('11. LOCAL_SCHEMA_UPGRADE — Database with schema v1 upgrades cleanly to v2', () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'cheesyos-v1-upgrade-'));
    const dbPath = path.join(tmpDir, 'v1_legacy.db');

    try {
      // Step A: Manually create a version 1 schema database
      const rawDb1 = new DatabaseSync(dbPath);
      rawDb1.exec(`
        PRAGMA foreign_keys = ON;
        CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT NOT NULL, slug TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
        PRAGMA user_version = 1;
      `);
      rawDb1.close();

      // Step B: Open with PosLocalDatabase (should detect v1 and migrate to v2)
      const dbManager = new PosLocalDatabase(dbPath);
      assert.equal(dbManager.getSchemaVersion(), 2);

      // Verify new tables pos_device_config and pos_sequences exist and function
      setLocalDeviceConfig(dbManager, {
        device_id: '22222222-2222-4222-8222-222222222222',
        terminal_code: 'T02',
        device_name: 'Migrated POS',
      });
      const config = getDeviceConfig(dbManager);
      assert.equal(config?.terminal_code, 'T02');

      dbManager.close();
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
