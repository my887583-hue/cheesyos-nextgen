import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PosLocalDatabase, saveOrderTransaction, getPendingOutboxEntries, getSyncCursor } from '@cheesyos/pos-local';
import { runPullCycle, CloudPullTransport, PushSyncError } from '../src/index.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const TEST_DB_PATH = path.join(__dirname, 'temp_pos_pull_test.db');

describe('CHEESYOS NEXTGEN POS DELTA PULL SUITE', () => {
  let dbManager: PosLocalDatabase;

  beforeEach(() => {
    if (fs.existsSync(TEST_DB_PATH)) fs.unlinkSync(TEST_DB_PATH);
    dbManager = new PosLocalDatabase(TEST_DB_PATH);
  });

  afterEach(() => {
    dbManager.close();
    if (fs.existsSync(TEST_DB_PATH)) fs.unlinkSync(TEST_DB_PATH);
  });

  it('1. SAME_TIMESTAMP_TEST: Bounded deterministic cursor (updated_at, id) retrieves all identical-timestamp rows across pages without skip or loop', async () => {
    const sameTimestamp = '2026-10-10T12:00:00.000Z';
    const mockCloudCategories = [
      { id: 'cat-001', name: 'Cat 1', slug: 'cat-1', display_order: 1, is_active: true, created_at: sameTimestamp, updated_at: sameTimestamp },
      { id: 'cat-002', name: 'Cat 2', slug: 'cat-2', display_order: 2, is_active: true, created_at: sameTimestamp, updated_at: sameTimestamp },
      { id: 'cat-003', name: 'Cat 3', slug: 'cat-3', display_order: 3, is_active: true, created_at: sameTimestamp, updated_at: sameTimestamp },
      { id: 'cat-004', name: 'Cat 4', slug: 'cat-4', display_order: 4, is_active: true, created_at: sameTimestamp, updated_at: sameTimestamp },
      { id: 'cat-005', name: 'Cat 5', slug: 'cat-5', display_order: 5, is_active: true, created_at: sameTimestamp, updated_at: sameTimestamp },
    ];

    const mockTransport: CloudPullTransport = {
      async fetchCategoriesDelta(cursor, limit) {
        return mockCloudCategories.filter(cat => {
          if (cursor.lastTimestamp === '1970-01-01T00:00:00.000Z') return true;
          if (cat.updated_at > cursor.lastTimestamp) return true;
          if (cat.updated_at === cursor.lastTimestamp && cat.id > cursor.lastId) return true;
          return false;
        }).slice(0, limit);
      }
    };

    const cycle1 = await runPullCycle({
      dbManager,
      transport: mockTransport,
      datasets: ['categories'],
      batchSize: 3,
    });

    assert.equal(cycle1.status, 'COMPLETED');
    assert.equal(cycle1.rowsApplied, 3);

    const cursor1 = dbManager.runTransaction(db => getSyncCursor(db, 'categories'));
    assert.equal(cursor1.lastUpdatedAt, sameTimestamp);
    assert.equal(cursor1.lastId, 'cat-003');

    const cycle2 = await runPullCycle({
      dbManager,
      transport: mockTransport,
      datasets: ['categories'],
      batchSize: 3,
    });

    assert.equal(cycle2.status, 'COMPLETED');
    assert.equal(cycle2.rowsApplied, 2);

    const cursor2 = dbManager.runTransaction(db => getSyncCursor(db, 'categories'));
    assert.equal(cursor2.lastUpdatedAt, sameTimestamp);
    assert.equal(cursor2.lastId, 'cat-005');

    const localCount = dbManager.runTransaction(db => {
      const row = db.prepare('SELECT COUNT(*) as c FROM categories').get() as { c: number };
      return row.c;
    });
    assert.equal(localCount, 5);
  });

  it('2. CURSOR_CRASH_TEST: Local transaction crash before commit rolls back data and preserves old cursor for idempotent retry', async () => {
    const mockCloudCategories = [
      { id: 'cat-100', name: 'Crashing Cat', slug: 'cat-crash', display_order: 1, is_active: true, created_at: '2026-10-10T10:00:00.000Z', updated_at: '2026-10-10T10:00:00.000Z' }
    ];

    const mockTransport: CloudPullTransport = {
      async fetchCategoriesDelta() {
        return mockCloudCategories;
      }
    };

    let crashTriggered = false;
    const failingDbManager = {
      runTransaction: (fn: any) => {
        if (!crashTriggered) {
          crashTriggered = true;
          const db = dbManager.getRawDb();
          db.exec('BEGIN IMMEDIATE');
          try {
            fn(db);
            throw new Error('SIMULATED_SQLITE_COMMIT_CRASH');
          } catch (err) {
            db.exec('ROLLBACK');
            throw err;
          }
        }
        return dbManager.runTransaction(fn);
      }
    };

    const cycle1 = await runPullCycle({
      dbManager: failingDbManager as any,
      transport: mockTransport,
      datasets: ['categories'],
      batchSize: 10,
    });

    assert.equal(cycle1.status, 'RETRYABLE_STOPPED');
    assert.equal(cycle1.lastError, 'SIMULATED_SQLITE_COMMIT_CRASH');

    dbManager.runTransaction(db => {
      const catRow = db.prepare('SELECT COUNT(*) as c FROM categories WHERE id = ?').get('cat-100') as { c: number };
      assert.equal(catRow.c, 0);

      const cursor = getSyncCursor(db, 'categories');
      assert.equal(cursor.lastUpdatedAt, '1970-01-01T00:00:00.000Z');
    });

    const cycle2 = await runPullCycle({
      dbManager,
      transport: mockTransport,
      datasets: ['categories'],
      batchSize: 10,
    });

    assert.equal(cycle2.status, 'COMPLETED');
    assert.equal(cycle2.rowsApplied, 1);

    dbManager.runTransaction(db => {
      const catRow = db.prepare('SELECT COUNT(*) as c FROM categories WHERE id = ?').get('cat-100') as { c: number };
      assert.equal(catRow.c, 1);

      const cursor = getSyncCursor(db, 'categories');
      assert.equal(cursor.lastUpdatedAt, '2026-10-10T10:00:00.000Z');
      assert.equal(cursor.lastId, 'cat-100');
    });
  });

  it('3. LOCAL_PENDING_WRITE_TEST & PENDING_PARENT_TEST: Cloud pull preserves local pending outbox records without overwriting them', async () => {
    const orderId = 'a1111111-1111-1111-1111-111111111111';
    const localOrder = {
      id: orderId,
      display_number: 'ORD-LOCAL-EDIT',
      channel: 'POS',
      order_type: 'DINE_IN',
      status: 'pending',
      subtotal: 50.00,
      tax_total: 2.50,
      discount_total: 0.00,
      delivery_charge: 0.00,
      grand_total: 52.50,
      device_id: 'POS-01',
      created_at: '2026-10-10T12:00:00.000Z',
      updated_at: '2026-10-10T12:00:00.000Z'
    };
    saveOrderTransaction(dbManager, localOrder as any, []);

    const outboxBefore = dbManager.runTransaction(db => getPendingOutboxEntries(db, 10));
    assert.equal(outboxBefore.length, 1);

    const cloudOrder = {
      id: orderId,
      display_number: 'ORD-CLOUD-STALE',
      channel: 'POS',
      order_type: 'DINE_IN',
      status: 'billed',
      subtotal: 10.00,
      tax_total: 0.50,
      discount_total: 0.00,
      delivery_charge: 0.00,
      grand_total: 10.50,
      device_id: 'WEB-01',
      created_at: '2026-10-10T12:00:00.000Z',
      updated_at: '2026-10-10T12:05:00.000Z'
    };

    const cloudOrderItem = {
      id: 'item-stale-01',
      order_id: orderId,
      product_id: 'p-01',
      product_name: 'Stale Item',
      unit_price: 10.00,
      quantity: 1,
      tax_rate: 5.00,
      discount_amount: 0.00,
      line_total: 10.00,
      created_at: '2026-10-10T12:05:00.000Z'
    };

    const mockTransport: CloudPullTransport = {
      async fetchOrdersDelta() {
        return { orders: [cloudOrder], orderItems: [cloudOrderItem] };
      }
    };

    const pullRes = await runPullCycle({
      dbManager,
      transport: mockTransport,
      datasets: ['orders'],
    });

    assert.equal(pullRes.status, 'COMPLETED');
    assert.equal(pullRes.rowsApplied, 0);

    dbManager.runTransaction(db => {
      const row = db.prepare('SELECT display_number, grand_total_paise FROM orders WHERE id = ?').get(orderId) as any;
      assert.equal(row.display_number, 'ORD-LOCAL-EDIT');
      assert.equal(row.grand_total_paise, 5250);

      const itemRow = db.prepare('SELECT COUNT(*) as c FROM order_items WHERE order_id = ?').get(orderId) as { c: number };
      assert.equal(itemRow.c, 0);
    });
  });

  it('4. NO_OUTBOX_ECHO_TEST: Cloud pull inserts categories, products, orders, and inventory state without generating outbox rows', async () => {
    const mockTransport: CloudPullTransport = {
      async fetchCategoriesDelta() {
        return [{ id: 'cat-200', name: 'Pull Cat', slug: 'pull-cat', display_order: 1, is_active: true, created_at: '2026-10-10T10:00:00.000Z', updated_at: '2026-10-10T10:00:00.000Z' }];
      },
      async fetchProductsDelta() {
        return [{ id: 'prod-200', category_id: 'cat-200', name: 'Pull Prod', base_price: 15.00, is_available: true, is_inventory_tracked: true, created_at: '2026-10-10T10:00:00.000Z', updated_at: '2026-10-10T10:00:00.000Z' }];
      },
      async fetchInventoryLiteDelta() {
        return [{ id: 'inv-200', product_id: 'prod-200', current_stock: 40, low_stock_threshold: 5, is_tracked: true, updated_at: '2026-10-10T10:00:00.000Z' }];
      }
    };

    const outboxBefore = dbManager.runTransaction(db => getPendingOutboxEntries(db, 10));
    assert.equal(outboxBefore.length, 0);

    const pullRes = await runPullCycle({
      dbManager,
      transport: mockTransport,
      datasets: ['categories', 'products', 'inventory_lite'],
    });

    assert.equal(pullRes.status, 'COMPLETED');
    assert.equal(pullRes.rowsApplied, 3);

    const outboxAfter = dbManager.runTransaction(db => getPendingOutboxEntries(db, 10));
    assert.equal(outboxAfter.length, 0);
  });

  it('5. NETWORK_FAILURE_TEST & AUTH_FAILURE_TEST: Network or Auth errors stop pull cycle safely without mutating cursor or local state', async () => {
    const networkTransport: CloudPullTransport = {
      async fetchCategoriesDelta() {
        throw new PushSyncError('RETRYABLE', 'Network connection timeout');
      }
    };

    const res1 = await runPullCycle({
      dbManager,
      transport: networkTransport,
      datasets: ['categories'],
    });

    assert.equal(res1.status, 'RETRYABLE_STOPPED');
    assert.equal(res1.lastError, 'Network connection timeout');

    const authTransport: CloudPullTransport = {
      async fetchCategoriesDelta() {
        throw new PushSyncError('AUTH_REQUIRED', 'JWT expired');
      }
    };

    const res2 = await runPullCycle({
      dbManager,
      transport: authTransport,
      datasets: ['categories'],
    });

    assert.equal(res2.status, 'AUTH_REQUIRED_STOPPED');
    assert.equal(res2.lastError, 'JWT expired');

    const cursor = dbManager.runTransaction(db => getSyncCursor(db, 'categories'));
    assert.equal(cursor.lastUpdatedAt, '1970-01-01T00:00:00.000Z');
  });

  it('6. IMMUTABILITY_CONFLICT_TEST: Cloud bill/payment payload mismatch against existing local record stops with CONTRACT_CONFLICT', async () => {
    const billId = 'bill-999';
    const orderId = 'ord-999';
    dbManager.runTransaction(db => {
      db.prepare(`
        INSERT INTO orders (id, display_number, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at)
        VALUES ('${orderId}', 'ORD-999', 'POS', 'DINE_IN', 'billed', 1000, 50, 0, 0, 1050, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      `).run();

      db.prepare(`
        INSERT INTO bills (id, order_id, bill_number, subtotal_paise, cgst_total_paise, sgst_total_paise, discount_total_paise, grand_total_paise, payment_status, finalized_at)
        VALUES ('${billId}', '${orderId}', 'BILL-999', 1000, 25, 25, 0, 1050, 'unpaid', CURRENT_TIMESTAMP)
      `).run();
    });

    const MismatchedCloudBill = {
      id: billId,
      order_id: orderId,
      bill_number: 'BILL-999',
      subtotal: 99.00,
      cgst_total: 2.50,
      sgst_total: 2.50,
      discount_total: 0.00,
      grand_total: 104.00,
      payment_status: 'unpaid',
      finalized_at: '2026-10-10T12:00:00.000Z'
    };

    const mockTransport: CloudPullTransport = {
      async fetchBillsDelta() {
        return [MismatchedCloudBill];
      }
    };

    const pullRes = await runPullCycle({
      dbManager,
      transport: mockTransport,
      datasets: ['bills'],
    });

    assert.equal(pullRes.status, 'CONTRACT_CONFLICT_STOPPED');
    assert.match(pullRes.lastError!, /Immutable bill payload mismatch/);
  });
});
