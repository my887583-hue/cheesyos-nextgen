import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {
  PosLocalDatabase,
  openTableSessionTransaction,
  saveOrderTransaction,
  saveBillWithSequenceTransaction,
  savePaymentTransaction,
  closeTableSessionTransaction,
  getPendingOutboxEntries,
  setLocalDeviceConfig,
} from '@cheesyos/pos-local';
import {
  runPushCycle,
  CloudRpcTransport,
  PushSyncError,
} from '../src/index.js';

const TEST_DB_PATH = path.join(process.cwd(), 'temp_pos_table_session_sync_test.db');

describe('CHEESYOS NEXTGEN POS TABLE SESSION PUSH SYNC SUITE (Task 3G.2-03B)', () => {
  let dbManager: PosLocalDatabase;

  beforeEach(() => {
    if (fs.existsSync(TEST_DB_PATH)) fs.unlinkSync(TEST_DB_PATH);
    if (fs.existsSync(`${TEST_DB_PATH}-wal`)) fs.unlinkSync(`${TEST_DB_PATH}-wal`);
    if (fs.existsSync(`${TEST_DB_PATH}-shm`)) fs.unlinkSync(`${TEST_DB_PATH}-shm`);
    dbManager = new PosLocalDatabase(TEST_DB_PATH);

    // Seed fixtures
    dbManager.runTransaction(db => {
      db.prepare(`
        INSERT INTO pos_tables (id, table_number, section, capacity, is_active, created_at)
        VALUES ('tbl-sync-1', 'T-10', 'Main', 4, 1, CURRENT_TIMESTAMP)
        ON CONFLICT (id) DO NOTHING
      `).run();
      db.prepare(`
        INSERT INTO categories (id, name, slug, display_order, is_active, created_at, updated_at)
        VALUES ('cat-sync-1', 'Main', 'main', 0, 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT (id) DO NOTHING
      `).run();
      db.prepare(`
        INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at)
        VALUES ('prod-sync-1', 'cat-sync-1', 'Burger', 10000, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT (id) DO NOTHING
      `).run();
    });
    setLocalDeviceConfig(dbManager, {
      device_id: 'dev-sync-1',
      terminal_code: 'T01',
      device_name: 'Counter',
    });
  });

  afterEach(() => {
    dbManager.close();
    if (fs.existsSync(TEST_DB_PATH)) fs.unlinkSync(TEST_DB_PATH);
    if (fs.existsSync(`${TEST_DB_PATH}-wal`)) fs.unlinkSync(`${TEST_DB_PATH}-wal`);
    if (fs.existsSync(`${TEST_DB_PATH}-shm`)) fs.unlinkSync(`${TEST_DB_PATH}-shm`);
  });

  it('TABLE_SESSION_PUSH_DISPATCH_PASS — runPushCycle dispatches table_sessions and acknowledges outbox', async () => {
    const session = openTableSessionTransaction(dbManager, 'tbl-sync-1', 2, 'sess-push-1');

    const syncedSessions: any[] = [];
    const mockTransport: CloudRpcTransport = {
      async syncTableSession(sess) {
        syncedSessions.push(sess);
        return true;
      },
      async syncOrder() { return true; },
      async syncKot() { return true; },
      async syncKotCorrection() { return true; },
      async syncBill() { return true; },
      async syncPayment() { return true; },
      async applyInventoryMovement() { return true; },
    };

    const result = await runPushCycle({
      dbManager,
      transport: mockTransport,
    });

    assert.equal(result.status, 'COMPLETED');
    assert.equal(result.processedCount, 1);
    assert.equal(result.successCount, 1);

    assert.equal(syncedSessions.length, 1);
    assert.equal(syncedSessions[0].id, 'sess-push-1');
    assert.equal(syncedSessions[0].table_id, 'tbl-sync-1');
    assert.equal(syncedSessions[0].session_status, 'open');

    const pending = dbManager.runTransaction(db => getPendingOutboxEntries(db));
    assert.equal(pending.length, 0);
  });

  it('TABLE_SESSION_PUSH_FAILURE_STOPS_QUEUE_PASS — failure in session push halts queue before order push', async () => {
    const session = openTableSessionTransaction(dbManager, 'tbl-sync-1', 2, 'sess-push-fail');
    const now = new Date().toISOString();
    saveOrderTransaction(
      dbManager,
      {
        id: 'ord-push-blocked',
        channel: 'POS',
        order_type: 'DINE_IN',
        table_session_id: session.id,
        status: 'pending',
        subtotal: 100,
        tax_total: 5,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 105,
        created_at: now,
        updated_at: now,
      },
      [
        {
          id: 'item-push-blocked',
          order_id: 'ord-push-blocked',
          product_id: 'prod-sync-1',
          product_name: 'Burger',
          unit_price: 100,
          quantity: 1,
          tax_rate: 5,
          discount_amount: 0,
          line_total: 105,
          created_at: now,
        },
      ]
    );

    let orderPushAttempted = false;
    const mockTransport: CloudRpcTransport = {
      async syncTableSession() {
        throw new PushSyncError('RETRYABLE', 'Network unreachable');
      },
      async syncOrder() {
        orderPushAttempted = true;
        return true;
      },
      async syncKot() { return true; },
      async syncKotCorrection() { return true; },
      async syncBill() { return true; },
      async syncPayment() { return true; },
      async applyInventoryMovement() { return true; },
    };

    const result = await runPushCycle({
      dbManager,
      transport: mockTransport,
    });

    assert.equal(result.status, 'RETRYABLE_STOPPED');
    assert.equal(result.processedCount, 1);
    assert.equal(result.successCount, 0);
    assert.equal(orderPushAttempted, false, 'Order push must NEVER be attempted if session push fails');

    // Both entries remain in outbox
    const pending = dbManager.runTransaction(db => getPendingOutboxEntries(db));
    assert.equal(pending.length, 2);
    assert.equal(pending[0].entity_type, 'table_sessions');
    assert.equal(pending[0].attempt_count, 1);
    assert.equal(pending[0].last_error, 'Network unreachable');
    assert.equal(pending[1].entity_type, 'orders');
  });

  it('OFFLINE_SESSION_THEN_ORDER_FK_SAFE_PASS — Session push precedes order push in strict FIFO order', async () => {
    const session = openTableSessionTransaction(dbManager, 'tbl-sync-1', 4, 'sess-fifo-1');
    const now = new Date().toISOString();
    saveOrderTransaction(
      dbManager,
      {
        id: 'ord-fifo-1',
        channel: 'POS',
        order_type: 'DINE_IN',
        table_session_id: session.id,
        status: 'pending',
        subtotal: 100,
        tax_total: 5,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 105,
        created_at: now,
        updated_at: now,
      },
      [
        {
          id: 'item-fifo-1',
          order_id: 'ord-fifo-1',
          product_id: 'prod-sync-1',
          product_name: 'Burger',
          unit_price: 100,
          quantity: 1,
          tax_rate: 5,
          discount_amount: 0,
          line_total: 105,
          created_at: now,
        },
      ]
    );

    const callLog: string[] = [];
    const mockTransport: CloudRpcTransport = {
      async syncTableSession(sess) {
        callLog.push(`session:${sess.id}`);
        return true;
      },
      async syncOrder(order) {
        callLog.push(`order:${order.id}:${order.table_session_id}`);
        return true;
      },
      async syncKot() { return true; },
      async syncKotCorrection() { return true; },
      async syncBill() { return true; },
      async syncPayment() { return true; },
      async applyInventoryMovement() { return true; },
    };

    const result = await runPushCycle({
      dbManager,
      transport: mockTransport,
    });

    assert.equal(result.status, 'COMPLETED');
    assert.equal(result.processedCount, 2);
    assert.equal(result.successCount, 2);

    assert.deepEqual(callLog, [
      'session:sess-fifo-1',
      'order:ord-fifo-1:sess-fifo-1',
    ]);
  });

  it('CLOSE_SYNC_PASS — Full lifecycle pushes open, order, bill, payment, and closed session', async () => {
    const now = new Date().toISOString();
    const session = openTableSessionTransaction(dbManager, 'tbl-sync-1', 2, 'sess-full-1');
    saveOrderTransaction(
      dbManager,
      {
        id: 'ord-full-1',
        channel: 'POS',
        order_type: 'DINE_IN',
        table_session_id: session.id,
        status: 'pending',
        subtotal: 100,
        tax_total: 5,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 105,
        created_at: now,
        updated_at: now,
      },
      [
        {
          id: 'item-full-1',
          order_id: 'ord-full-1',
          product_id: 'prod-sync-1',
          product_name: 'Burger',
          unit_price: 100,
          quantity: 1,
          tax_rate: 5,
          discount_amount: 0,
          line_total: 105,
          created_at: now,
        },
      ]
    );

    saveBillWithSequenceTransaction(dbManager, {
      id: 'bill-full-1',
      order_id: 'ord-full-1',
      bill_number: 'PENDING',
      subtotal: 100,
      cgst_total: 2.5,
      sgst_total: 2.5,
      discount_total: 0,
      grand_total: 105,
      payment_status: 'unpaid',
      finalized_at: now,
    });

    savePaymentTransaction(
      dbManager,
      {
        id: 'pay-full-1',
        bill_id: 'bill-full-1',
        order_id: 'ord-full-1',
        payment_mode: 'CASH',
        amount_paid: 105,
        confirmed_at: now,
      },
      {
        id: 'bill-full-1',
        order_id: 'ord-full-1',
        bill_number: 'CB-T01-000001',
        subtotal: 100,
        cgst_total: 2.5,
        sgst_total: 2.5,
        discount_total: 0,
        grand_total: 105,
        payment_status: 'paid',
        finalized_at: now,
      }
    );

    closeTableSessionTransaction(dbManager, 'sess-full-1', 'ord-full-1', now);

    const callLog: string[] = [];
    const mockTransport: CloudRpcTransport = {
      async syncTableSession(sess) {
        callLog.push(`session:${sess.id}:${sess.session_status}`);
        return true;
      },
      async syncOrder(order) {
        callLog.push(`order:${order.id}`);
        return true;
      },
      async syncKot() { return true; },
      async syncKotCorrection() { return true; },
      async syncBill(bill) {
        callLog.push(`bill:${bill.id}`);
        return true;
      },
      async syncPayment(payment) {
        callLog.push(`payment:${payment.id}`);
        return true;
      },
      async applyInventoryMovement() { return true; },
    };

    const result = await runPushCycle({
      dbManager,
      transport: mockTransport,
    });

    assert.equal(result.status, 'COMPLETED');
    assert.deepEqual(callLog, [
      'session:sess-full-1:open',
      'order:ord-full-1',
      'session:sess-full-1:billed',
      'bill:bill-full-1',
      'payment:pay-full-1',
      'session:sess-full-1:closed',
    ]);

    const pending = dbManager.runTransaction(db => getPendingOutboxEntries(db));
    assert.equal(pending.length, 0);
  });
});
