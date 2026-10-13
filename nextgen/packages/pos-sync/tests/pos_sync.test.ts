import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {
  PosLocalDatabase,
  saveOrderTransaction,
  saveKotDispatchTransaction,
  saveKotCorrectionTransaction,
  saveBillTransaction,
  savePaymentTransaction,
  saveInventoryMovementTransaction,
  getPendingOutboxEntries
} from '@cheesyos/pos-local';
import {
  runPushCycle,
  CloudRpcTransport,
  PushSyncError
} from '../src/index.js';

const TEST_DB_PATH = path.join(process.cwd(), 'temp_pos_sync_test.db');

describe('CHEESYOS NEXTGEN POS PUSH SYNC SUITE', () => {
  let dbManager: PosLocalDatabase;

  beforeEach(() => {
    if (fs.existsSync(TEST_DB_PATH)) fs.unlinkSync(TEST_DB_PATH);
    if (fs.existsSync(`${TEST_DB_PATH}-wal`)) fs.unlinkSync(`${TEST_DB_PATH}-wal`);
    if (fs.existsSync(`${TEST_DB_PATH}-shm`)) fs.unlinkSync(`${TEST_DB_PATH}-shm`);
    dbManager = new PosLocalDatabase(TEST_DB_PATH);
  });

  afterEach(() => {
    dbManager.close();
    if (fs.existsSync(TEST_DB_PATH)) fs.unlinkSync(TEST_DB_PATH);
    if (fs.existsSync(`${TEST_DB_PATH}-wal`)) fs.unlinkSync(`${TEST_DB_PATH}-wal`);
    if (fs.existsSync(`${TEST_DB_PATH}-shm`)) fs.unlinkSync(`${TEST_DB_PATH}-shm`);
  });

  function seedCategory(categoryId: string = 'cat-1') {
    dbManager.runTransaction(db => {
      db.prepare(`
        INSERT INTO categories (id, name, slug, display_order, is_active, created_at, updated_at)
        VALUES (?, 'Cat 1', 'cat-1', 0, 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT (id) DO NOTHING
      `).run(categoryId);
    });
  }

  function seedProduct(productId: string, categoryId: string = 'cat-1') {
    seedCategory(categoryId);
    dbManager.runTransaction(db => {
      db.prepare(`
        INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at)
        VALUES (?, ?, 'Test Product', 1000, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT (id) DO NOTHING
      `).run(productId, categoryId);
      db.prepare(`
        INSERT INTO inventory_lite (product_id, current_stock, updated_at)
        VALUES (?, 100, CURRENT_TIMESTAMP)
        ON CONFLICT (product_id) DO NOTHING
      `).run(productId);
    });
  }

  function seedOrder(orderId: string) {
    dbManager.runTransaction(db => {
      db.prepare(`
        INSERT INTO orders (id, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at)
        VALUES (?, 'POS', 'DINE_IN', 'pending', 1000, 50, 0, 0, 1050, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT (id) DO NOTHING
      `).run(orderId);
    });
  }

  function seedBill(billId: string, orderId: string) {
    seedOrder(orderId);
    dbManager.runTransaction(db => {
      db.prepare(`UPDATE orders SET status = 'billed' WHERE id = ?`).run(orderId);
      db.prepare(`
        INSERT INTO bills (id, order_id, bill_number, subtotal_paise, cgst_total_paise, sgst_total_paise, discount_total_paise, grand_total_paise, payment_status, finalized_at)
        VALUES (?, ?, 'B-TEST', 1000, 25, 25, 0, 1050, 'unpaid', CURRENT_TIMESTAMP)
        ON CONFLICT (id) DO NOTHING
      `).run(billId, orderId);
    });
  }

  function createMockTransport(overrides?: Partial<CloudRpcTransport>): CloudRpcTransport & { calls: Array<{ name: string; args: any }> } {
    const calls: Array<{ name: string; args: any }> = [];
    return {
      calls,
      async syncOrder(order, items) {
        calls.push({ name: 'syncOrder', args: { order, items } });
        return overrides?.syncOrder ? overrides.syncOrder(order, items) : true;
      },
      async syncKot(kot, items) {
        calls.push({ name: 'syncKot', args: { kot, items } });
        return overrides?.syncKot ? overrides.syncKot(kot, items) : true;
      },
      async syncKotCorrection(correction) {
        calls.push({ name: 'syncKotCorrection', args: { correction } });
        return overrides?.syncKotCorrection ? overrides.syncKotCorrection(correction) : true;
      },
      async syncBill(bill) {
        calls.push({ name: 'syncBill', args: { bill } });
        return overrides?.syncBill ? overrides.syncBill(bill) : true;
      },
      async syncPayment(payment) {
        calls.push({ name: 'syncPayment', args: { payment } });
        return overrides?.syncPayment ? overrides.syncPayment(payment) : true;
      },
      async syncTableSession(session) {
        calls.push({ name: 'syncTableSession', args: { session } });
        return overrides?.syncTableSession ? overrides.syncTableSession(session) : true;
      },
      async applyInventoryMovement(input) {
        calls.push({ name: 'applyInventoryMovement', args: input });
        return overrides?.applyInventoryMovement ? overrides.applyInventoryMovement(input) : true;
      },
    };
  }

  it('1. LOCAL_SUCCESS_TEST & ORDER_AGGREGATE_TEST: Order + 2 items pushed as 1 request & ACKed atomically', async () => {
    seedProduct('p1');
    seedProduct('p2');

    const order = {
      id: 'a1111111-1111-1111-1111-111111111111',
      display_number: 'ORD-101',
      channel: 'POS' as const,
      order_type: 'DINE_IN' as const,
      status: 'pending' as const,
      subtotal: 24.00,
      tax_total: 1.20,
      discount_total: 0.00,
      delivery_charge: 0.00,
      grand_total: 25.20,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString()
    };
    const items = [
      { id: 'b1111111-1111-1111-1111-111111111111', order_id: order.id, product_id: 'p1', product_name: 'Item 1', unit_price: 10.00, quantity: 1, tax_rate: 5, discount_amount: 0, line_total: 10.00, created_at: order.created_at },
      { id: 'b2222222-2222-2222-2222-222222222222', order_id: order.id, product_id: 'p2', product_name: 'Item 2', unit_price: 14.00, quantity: 1, tax_rate: 5, discount_amount: 0, line_total: 14.00, created_at: order.created_at }
    ];

    saveOrderTransaction(dbManager, order, items);
    let pendingBefore = dbManager.runTransaction(db => getPendingOutboxEntries(db, 10));
    assert.equal(pendingBefore.length, 1);

    const transport = createMockTransport();
    const result = await runPushCycle({ dbManager, transport, batchSize: 10 });

    assert.equal(result.status, 'COMPLETED');
    assert.equal(result.processedCount, 1);
    assert.equal(result.successCount, 1);
    assert.equal(transport.calls.length, 1);
    assert.equal(transport.calls[0].name, 'syncOrder');

    let pendingAfter = dbManager.runTransaction(db => getPendingOutboxEntries(db, 10));
    assert.equal(pendingAfter.length, 0);
  });

  it('2. KOT_AGGREGATE_TEST: KOT + items pushed as 1 request & ACKed atomically', async () => {
    seedOrder('a1111111-1111-1111-1111-111111111111');
    seedProduct('p1');

    const kot = {
      id: 'k1111111-1111-1111-1111-111111111111',
      order_id: 'a1111111-1111-1111-1111-111111111111',
      kot_number: 1,
      status: 'printed' as const,
      printed_at: new Date().toISOString()
    };
    const items = [
      { id: 'ki111111-1111-1111-1111-111111111111', kot_id: kot.id, product_id: 'p1', product_name: 'Item 1', quantity: 1 }
    ];

    saveKotDispatchTransaction(dbManager, kot, items);
    const transport = createMockTransport();
    const result = await runPushCycle({ dbManager, transport });

    assert.equal(result.status, 'COMPLETED');
    assert.equal(transport.calls.length, 1);
    assert.equal(transport.calls[0].name, 'syncKot');

    let pendingAfter = dbManager.runTransaction(db => getPendingOutboxEntries(db, 10));
    assert.equal(pendingAfter.length, 0);
  });

  it('3. NETWORK_FAILURE_TEST: Retryable network error leaves outbox pending and stops cycle', async () => {
    seedOrder('ord-1');
    saveBillTransaction(dbManager, {
      id: 'bill-1',
      order_id: 'ord-1',
      bill_number: 'B-1',
      subtotal: 10,
      cgst_total: 0.5,
      sgst_total: 0.5,
      discount_total: 0,
      grand_total: 11,
      payment_status: 'unpaid',
      finalized_at: new Date().toISOString()
    });

    const transport = createMockTransport({
      async syncBill() {
        throw new PushSyncError('RETRYABLE', 'Network connection reset by peer');
      }
    });

    const result = await runPushCycle({ dbManager, transport });
    assert.equal(result.status, 'RETRYABLE_STOPPED');
    assert.equal(result.successCount, 0);

    let pendingAfter = dbManager.runTransaction(db => getPendingOutboxEntries(db, 10));
    assert.equal(pendingAfter.length, 1);
    assert.equal(pendingAfter[0].attempt_count, 1);
    assert.equal(pendingAfter[0].last_error, 'Network connection reset by peer');
  });

  it('4. AUTH_FAILURE_TEST: Auth failure returns AUTH_REQUIRED_STOPPED', async () => {
    seedOrder('ord-2');
    saveBillTransaction(dbManager, {
      id: 'bill-2',
      order_id: 'ord-2',
      bill_number: 'B-2',
      subtotal: 10,
      cgst_total: 0.5,
      sgst_total: 0.5,
      discount_total: 0,
      grand_total: 11,
      payment_status: 'unpaid',
      finalized_at: new Date().toISOString()
    });

    const transport = createMockTransport({
      async syncBill() {
        throw new PushSyncError('AUTH_REQUIRED', 'Access Denied: Active staff profile required');
      }
    });

    const result = await runPushCycle({ dbManager, transport });
    assert.equal(result.status, 'AUTH_REQUIRED_STOPPED');
    assert.equal(result.successCount, 0);
  });

  it('5. CONTRACT_CONFLICT_TEST: Contract mismatch returns CONTRACT_CONFLICT_STOPPED', async () => {
    seedOrder('ord-3');
    saveBillTransaction(dbManager, {
      id: 'bill-3',
      order_id: 'ord-3',
      bill_number: 'B-3',
      subtotal: 10,
      cgst_total: 0.5,
      sgst_total: 0.5,
      discount_total: 0,
      grand_total: 11,
      payment_status: 'unpaid',
      finalized_at: new Date().toISOString()
    });

    const transport = createMockTransport({
      async syncBill() {
        throw new PushSyncError('CONTRACT_CONFLICT', 'CONTRACT_CONFLICT: Bill ID bill-3 already exists with mismatched payload');
      }
    });

    const result = await runPushCycle({ dbManager, transport });
    assert.equal(result.status, 'CONTRACT_CONFLICT_STOPPED');
  });

  it('6. PAYMENT_ACK_CRASH_TEST & INVENTORY_RETRY_TEST: Retry sends EXACT same payment & inventory UUIDs', async () => {
    seedBill('b-9', 'o-9');
    seedProduct('p-8');

    const paymentId = 'pay-uuid-999';
    savePaymentTransaction(dbManager, {
      id: paymentId,
      bill_id: 'b-9',
      order_id: 'o-9',
      payment_mode: 'CASH',
      amount_paid: 20,
      confirmed_at: new Date().toISOString()
    }, {
      id: 'b-9',
      order_id: 'o-9',
      bill_number: 'B-9',
      subtotal: 20,
      cgst_total: 0,
      sgst_total: 0,
      discount_total: 0,
      grand_total: 20,
      payment_status: 'paid',
      finalized_at: new Date().toISOString()
    });

    const movementId = 'move-uuid-888';
    saveInventoryMovementTransaction(dbManager, {
      id: movementId,
      productId: 'p-8',
      movementType: 'SALE',
      quantityChange: -2
    });

    let callCount = 0;
    const transport = createMockTransport({
      async syncPayment(payment) {
        callCount++;
        assert.equal(payment.id, paymentId);
        if (callCount === 1) {
          throw new PushSyncError('RETRYABLE', 'Simulated ACK crash after cloud call');
        }
        return true;
      },
      async applyInventoryMovement(input) {
        assert.equal(input.movementId, movementId);
        return true;
      }
    });

    // Cycle 1: Fails at payment ACK
    const res1 = await runPushCycle({ dbManager, transport });
    assert.equal(res1.status, 'RETRYABLE_STOPPED');

    // Cycle 2: Retries SAME payment UUID, then succeeds with inventory movement using SAME movement UUID
    const res2 = await runPushCycle({ dbManager, transport });
    assert.equal(res2.status, 'COMPLETED');
    assert.equal(res2.successCount, 2);

    let pendingAfter = dbManager.runTransaction(db => getPendingOutboxEntries(db, 10));
    assert.equal(pendingAfter.length, 0);
  });

  it('7. DEPENDENCY_TEST: Stop at first failure prevents pushing dependent KOT/Bill/Payment', async () => {
    seedOrder('dep-order');

    // 1. Order
    saveOrderTransaction(dbManager, {
      id: 'dep-order-2',
      channel: 'POS' as const,
      order_type: 'DINE_IN' as const,
      status: 'pending' as const,
      subtotal: 10,
      tax_total: 0,
      discount_total: 0,
      delivery_charge: 0,
      grand_total: 10,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString()
    }, []);

    // 2. KOT
    saveKotDispatchTransaction(dbManager, {
      id: 'dep-kot',
      order_id: 'dep-order',
      kot_number: 1,
      status: 'printed' as const,
      printed_at: new Date().toISOString()
    }, []);

    // 3. Bill
    saveBillTransaction(dbManager, {
      id: 'dep-bill',
      order_id: 'dep-order',
      bill_number: 'B-DEP',
      subtotal: 10,
      cgst_total: 0,
      sgst_total: 0,
      discount_total: 0,
      grand_total: 10,
      payment_status: 'unpaid',
      finalized_at: new Date().toISOString()
    });

    const transport = createMockTransport({
      async syncOrder() {
        throw new PushSyncError('RETRYABLE', 'Order cloud push failed');
      }
    });

    const result = await runPushCycle({ dbManager, transport });
    assert.equal(result.status, 'RETRYABLE_STOPPED');
    assert.equal(result.processedCount, 1);
    assert.equal(result.successCount, 0);
    assert.equal(transport.calls.length, 1);
    assert.equal(transport.calls[0].name, 'syncOrder');
  });

  it('8. BATCH_LIMIT_TEST & SEQUENTIAL_TEST: Respects max batch size 10 and processes sequentially', async () => {
    seedOrder('ord-seq');

    for (let i = 1; i <= 15; i++) {
      saveKotCorrectionTransaction(dbManager, {
        id: `corr-${i}`,
        order_id: 'ord-seq',
        product_name: `Product ${i}`,
        cancelled_qty: 1,
        reason: 'Test',
        authorized_by_staff_id: 'staff-1',
        created_at: new Date().toISOString()
      });
    }

    const transport = createMockTransport();
    const result = await runPushCycle({ dbManager, transport, batchSize: 20 }); // Request 20, but capped at MAX 10

    assert.equal(result.status, 'COMPLETED');
    assert.equal(result.processedCount, 10);
    assert.equal(result.successCount, 10);
    assert.equal(transport.calls.length, 10);

    // Verify sequential execution order (seq 1 to 10)
    for (let i = 0; i < 10; i++) {
      assert.equal(transport.calls[i].args.correction.id, `corr-${i + 1}`);
    }

    let pendingAfter = dbManager.runTransaction(db => getPendingOutboxEntries(db, 20));
    assert.equal(pendingAfter.length, 5); // 5 entries remain for next cycle
  });
});
