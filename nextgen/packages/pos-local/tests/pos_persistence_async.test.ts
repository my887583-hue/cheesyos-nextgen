/**
 * CHEESYOS NEXTGEN POS LOCAL — ASYNC SEMANTIC PERSISTENCE CONTRACT & NODE PARITY SUITE
 * 
 * Verifies that PosLocalDatabase implements IPosPersistence with 100% Node SQLite parity:
 * - All 13 methods are asynchronous (Promise-based).
 * - Single-transaction atomicity across aggregates, bills, payments, inventory, and outbox.
 * - Authoritative bill numbering generated from terminal_code + sequence atomically.
 * - Caller-provided conflicting bill number is strictly rejected.
 * - Zero raw SQL strings cross the IPosPersistence interface.
 * - No sync echo and robust pending protection during applyPullBatch.
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import {
  OrderDomain,
  OrderItemDomain,
  PosKotDomain,
  KotItemDomain,
  KotCorrectionDomain,
  BillDomain,
  PaymentDomain,
} from '@cheesyos/nextgen-shared';
import {
  PosLocalDatabase,
  IPosPersistence,
} from '../src/index.js';

function seedPrerequisites(posDb: PosLocalDatabase, orderId?: string) {
  const raw = posDb.getRawDb();
  raw.prepare(`INSERT OR IGNORE INTO categories (id, name, slug, created_at, updated_at) VALUES ('c1', 'Food', 'food', 'now', 'now')`).run();
  raw.prepare(`INSERT OR IGNORE INTO products (id, category_id, name, base_price_paise, created_at, updated_at) VALUES ('prod-p1', 'c1', 'Pizza', 10000, 'now', 'now')`).run();
  if (orderId) {
    raw.prepare(`INSERT OR IGNORE INTO orders (id, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at) VALUES (?, 'POS', 'DINE_IN', 'pending', 10000, 500, 0, 0, 10500, 'now', 'now')`).run(orderId);
  }
}

function createTestOrder(id: string = 'ord-async-1'): { order: OrderDomain; items: OrderItemDomain[] } {
  const now = new Date().toISOString();
  return {
    order: {
      id,
      channel: 'POS',
      order_type: 'DINE_IN',
      status: 'pending',
      subtotal: 100,
      tax_total: 5,
      discount_total: 0,
      delivery_charge: 0,
      grand_total: 105,
      created_at: now,
      updated_at: now,
    },
    items: [
      {
        id: `item-${id}-1`,
        order_id: id,
        product_id: 'prod-p1',
        product_name: 'Cheese Pizza',
        unit_price: 100,
        quantity: 1,
        tax_rate: 5,
        discount_amount: 0,
        line_total: 105,
        created_at: now,
      },
    ],
  };
}

describe('Phase 3F.5E1 — Async Semantic Persistence Contract & Node Parity', () => {
  test('1. DEVICE_CONFIG_ASYNC_PARITY — setDeviceConfig and getDeviceConfig return Promise-based identity', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    const db: IPosPersistence = posDb;

    const config = await db.setDeviceConfig({
      device_id: 'dev-001',
      terminal_code: 't01',
      device_name: 'Main POS Terminal',
    });

    assert.equal(config.device_id, 'dev-001');
    assert.equal(config.terminal_code, 'T01'); // Auto-normalized uppercase
    assert.equal(config.device_name, 'Main POS Terminal');

    const read = await db.getDeviceConfig();
    assert.notEqual(read, null);
    assert.equal(read?.terminal_code, 'T01');
    assert.equal(read?.device_id, 'dev-001');

    posDb.close();
  });

  test('2. ORDER_AGGREGATE_ASYNC_PARITY — saveOrderAggregate commits order, items, and outbox atomically', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedPrerequisites(posDb);
    const db: IPosPersistence = posDb;
    const { order, items } = createTestOrder('ord-101');

    const result = await db.saveOrderAggregate(order, items);

    assert.equal(result.order.id, 'ord-101');
    assert.equal(result.items.length, 1);
    assert.equal(result.outboxEntries.length, 1);
    assert.equal(result.outboxEntries[0].entity_type, 'orders');
    assert.equal(result.outboxEntries[0].entity_id, 'ord-101');

    // Verify outbox queue read
    const pending = await db.getPendingOutbox(10);
    assert.equal(pending.length, 1);
    assert.equal(pending[0].entity_id, 'ord-101');

    posDb.close();
  });

  test('3. KOT_AGGREGATE_AND_CORRECTION_ASYNC_PARITY — saveKotAggregate and saveKotCorrection create durable records', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedPrerequisites(posDb, 'ord-101');
    const db: IPosPersistence = posDb;
    const now = new Date().toISOString();

    const kot: PosKotDomain = {
      id: 'kot-101',
      order_id: 'ord-101',
      kot_number: 1,
      status: 'printed',
      printed_at: now,
    };
    const items: KotItemDomain[] = [
      {
        id: 'ki-1',
        kot_id: 'kot-101',
        product_id: 'prod-p1',
        product_name: 'Cheese Pizza',
        quantity: 1,
      },
    ];

    const kotResult = await db.saveKotAggregate(kot, items);
    assert.equal(kotResult.kot.id, 'kot-101');
    assert.equal(kotResult.outboxEntries.length, 1);
    assert.equal(kotResult.outboxEntries[0].entity_type, 'pos_kots');

    const correction: KotCorrectionDomain = {
      id: 'cor-101',
      order_id: 'ord-101',
      kot_id: 'kot-101',
      product_name: 'Cheese Pizza',
      cancelled_qty: 1,
      reason: 'Customer cancelled',
      authorized_by_staff_id: 'staff-1',
      created_at: now,
    };

    const corResult = await db.saveKotCorrection(correction);
    assert.equal(corResult.entity_type, 'kot_corrections');
    assert.equal(corResult.entity_id, 'cor-101');

    const pending = await db.getPendingOutbox(10);
    assert.equal(pending.length, 2);

    posDb.close();
  });

  test('4. BILL_SEQUENCE_ATOMICITY_AND_CONFLICT_GATE — saveBillWithSequence generates authoritative bill number & rejects caller conflict', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedPrerequisites(posDb, 'ord-101');
    posDb.getRawDb().prepare(`INSERT OR IGNORE INTO orders (id, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at) VALUES ('ord-102', 'POS', 'DINE_IN', 'pending', 20000, 1000, 0, 0, 21000, 'now', 'now')`).run();
    posDb.getRawDb().prepare(`INSERT OR IGNORE INTO orders (id, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at) VALUES ('ord-103', 'POS', 'DINE_IN', 'pending', 5000, 250, 0, 0, 5250, 'now', 'now')`).run();

    const db: IPosPersistence = posDb;
    const now = new Date().toISOString();

    // Configure terminal
    await db.setDeviceConfig({
      device_id: 'dev-001',
      terminal_code: 'T01',
      device_name: 'Counter 1',
    });

    const bill1: BillDomain = {
      id: 'bill-1',
      order_id: 'ord-101',
      bill_number: 'PENDING', // Draft placeholder
      subtotal: 100,
      cgst_total: 2.5,
      sgst_total: 2.5,
      discount_total: 0,
      grand_total: 105,
      payment_status: 'unpaid',
      finalized_at: now,
    };

    const res1 = await db.saveBillWithSequence(bill1);
    assert.equal(res1.sequenceNumber, 1);
    assert.equal(res1.bill.bill_number, 'CB-T01-000001');
    assert.equal(res1.outboxEntry.entity_type, 'bills');

    // Second bill receives monotonic sequence 2
    const bill2: BillDomain = {
      id: 'bill-2',
      order_id: 'ord-102',
      bill_number: '',
      subtotal: 200,
      cgst_total: 5,
      sgst_total: 5,
      discount_total: 0,
      grand_total: 210,
      payment_status: 'unpaid',
      finalized_at: now,
    };

    const res2 = await db.saveBillWithSequence(bill2);
    assert.equal(res2.sequenceNumber, 2);
    assert.equal(res2.bill.bill_number, 'CB-T01-000002');

    // HARD GATE: Conflicting caller-provided bill number must be strictly rejected
    const conflictingBill: BillDomain = {
      id: 'bill-3',
      order_id: 'ord-103',
      bill_number: 'CB-T01-000999', // Inconsistent with current sequence 3
      subtotal: 50,
      cgst_total: 1.25,
      sgst_total: 1.25,
      discount_total: 0,
      grand_total: 52.5,
      payment_status: 'unpaid',
      finalized_at: now,
    };

    await assert.rejects(
      async () => {
        await db.saveBillWithSequence(conflictingBill);
      },
      /BILL_NUMBER_CONFLICT/
    );

    // Rollback invariant: failed allocation did not consume sequence 3
    const nextBill: BillDomain = {
      id: 'bill-3-valid',
      order_id: 'ord-103',
      bill_number: 'PENDING',
      subtotal: 50,
      cgst_total: 1.25,
      sgst_total: 1.25,
      discount_total: 0,
      grand_total: 52.5,
      payment_status: 'unpaid',
      finalized_at: now,
    };

    const res3 = await db.saveBillWithSequence(nextBill);
    assert.equal(res3.sequenceNumber, 3);
    assert.equal(res3.bill.bill_number, 'CB-T01-000003');

    posDb.close();
  });

  test('5. PAYMENT_ASYNC_PARITY — savePayment records settlement and updates bill payment_status', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedPrerequisites(posDb, 'ord-pay-1');
    const db: IPosPersistence = posDb;
    const now = new Date().toISOString();

    await db.setDeviceConfig({
      device_id: 'dev-001',
      terminal_code: 'T01',
      device_name: 'Counter 1',
    });

    const billRes = await db.saveBillWithSequence({
      id: 'bill-pay-1',
      order_id: 'ord-pay-1',
      bill_number: 'PENDING',
      subtotal: 100,
      cgst_total: 2.5,
      sgst_total: 2.5,
      discount_total: 0,
      grand_total: 105,
      payment_status: 'unpaid',
      finalized_at: now,
    });

    const payment: PaymentDomain = {
      id: 'pay-1',
      bill_id: 'bill-pay-1',
      order_id: 'ord-pay-1',
      payment_mode: 'UPI',
      amount_paid: 105,
      confirmed_by_staff_id: 'staff-1',
      confirmed_at: now,
    };

    const updatedBill: BillDomain = {
      ...billRes.bill,
      payment_status: 'paid',
    };

    const payRes = await db.savePayment(payment, updatedBill);
    assert.equal(payRes.payment.id, 'pay-1');
    assert.equal(payRes.updatedBill.payment_status, 'paid');
    assert.equal(payRes.outboxEntry.entity_type, 'payments');

    posDb.close();
  });

  test('6. INVENTORY_ASYNC_PARITY — saveInventoryMovement persists stock change and fixed movement UUID', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedPrerequisites(posDb);
    const db: IPosPersistence = posDb;

    // Seed tracked product in inventory_lite
    posDb.runTransaction((raw) => {
      raw.prepare(`
        INSERT INTO inventory_lite (id, product_id, current_stock, low_stock_threshold, is_tracked, updated_at)
        VALUES ('inv-1', 'prod-p1', 10, 2, 1, CURRENT_TIMESTAMP)
      `).run();
    });

    const moveRes = await db.saveInventoryMovement({
      id: 'move-uuid-1',
      productId: 'prod-p1',
      movementType: 'SALE',
      quantityChange: -2,
    });

    assert.equal(moveRes.movementId, 'move-uuid-1');
    assert.equal(moveRes.newStock, 8);
    assert.equal(moveRes.outboxEntry.entity_type, 'inventory_movements');
    assert.equal(moveRes.outboxEntry.entity_id, 'move-uuid-1');

    posDb.close();
  });

  test('7. OUTBOX_LIFECYCLE_ASYNC_PARITY — getPendingOutbox, updateOutboxFailure, and acknowledgeOutbox work cleanly', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedPrerequisites(posDb);
    const db: IPosPersistence = posDb;
    const { order, items } = createTestOrder('ord-life-1');
    await db.saveOrderAggregate(order, items);

    const pending = await db.getPendingOutbox(10);
    assert.equal(pending.length, 1);
    const seq = pending[0].seq;

    // Record failure
    await db.updateOutboxFailure(seq, 'Temporary network timeout');
    const failed = await db.getPendingOutbox(10);
    assert.equal(failed[0].attempt_count, 1);
    assert.equal(failed[0].last_error, 'Temporary network timeout');

    // Acknowledge upon success
    await db.acknowledgeOutbox(seq);
    const afterAck = await db.getPendingOutbox(10);
    assert.equal(afterAck.length, 0);

    posDb.close();
  });

  test('8. SYNC_CURSOR_AND_APPLY_PULL_BATCH_ASYNC_PARITY — applyPullBatch inserts data and advances cursor without outbox echo', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    const db: IPosPersistence = posDb;

    // Initial cursor
    const initialCursor = await db.getSyncCursor('categories');
    assert.equal(initialCursor.lastUpdatedAt, '1970-01-01T00:00:00.000Z');

    const categoriesBatch = [
      {
        id: 'cat-1',
        name: 'Beverages',
        slug: 'beverages',
        display_order: 1,
        is_active: 1,
        created_at: '2026-10-10T10:00:00.000Z',
        updated_at: '2026-10-10T10:00:00.000Z',
      },
    ];

    const applied = await db.applyPullBatch(
      'categories',
      categoriesBatch,
      { lastUpdatedAt: '2026-10-10T10:00:00.000Z', lastId: 'cat-1' }
    );

    assert.equal(applied, 1);

    // Cursor advanced
    const updatedCursor = await db.getSyncCursor('categories');
    assert.equal(updatedCursor.lastUpdatedAt, '2026-10-10T10:00:00.000Z');
    assert.equal(updatedCursor.lastId, 'cat-1');

    // Invariant: ZERO outbox echo
    const outbox = await db.getPendingOutbox(10);
    assert.equal(outbox.length, 0);

    posDb.close();
  });

  test('9. PULL_SAFE_PREFIX_CURSOR_AND_PENDING_PROTECTION_ASYNC_PARITY — applyPullBatch stops at pending row & advances only to safe prefix', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedPrerequisites(posDb);
    const db: IPosPersistence = posDb;

    const T = '2026-10-10T12:00:00.000Z';

    // Mark prod-B as pending by saving an order with prod-B or inserting outbox entry
    posDb.runTransaction(rawDb => {
      rawDb.prepare(`
        INSERT INTO sync_outbox (id, entity_type, entity_id, operation, payload_json, created_at)
        VALUES ('out-prod-B', 'products', 'prod-B', 'INSERT', '{}', '${T}')
      `).run();
    });

    const batch = [
      { id: 'prod-A', category_id: 'c1', name: 'Product A', base_price: 10, is_available: true, created_at: T, updated_at: T },
      { id: 'prod-B', category_id: 'c1', name: 'Product B', base_price: 20, is_available: true, created_at: T, updated_at: T },
      { id: 'prod-C', category_id: 'c1', name: 'Product C', base_price: 30, is_available: true, created_at: T, updated_at: T },
    ];

    const applied = await db.applyPullBatch(
      'products',
      batch,
      { lastUpdatedAt: T, lastId: 'prod-C' }
    );

    // Only prod-A before pending prod-B applied
    assert.equal(applied, 1);

    // Cursor must NOT advance past prod-B to prod-C; must remain at prod-A
    const cursor = await db.getSyncCursor('products');
    assert.equal(cursor.lastUpdatedAt, T);
    assert.equal(cursor.lastId, 'prod-A');

    // Simulate push ACK
    posDb.runTransaction(rawDb => {
      rawDb.prepare("DELETE FROM sync_outbox WHERE entity_id = 'prod-B'").run();
    });

    // Next pull batch with remaining rows applies them and advances cursor
    const applied2 = await db.applyPullBatch(
      'products',
      [batch[1], batch[2]],
      { lastUpdatedAt: T, lastId: 'prod-C' }
    );

    assert.equal(applied2, 2);
    const finalCursor = await db.getSyncCursor('products');
    assert.equal(finalCursor.lastUpdatedAt, T);
    assert.equal(finalCursor.lastId, 'prod-C');

    posDb.close();
  });
});
