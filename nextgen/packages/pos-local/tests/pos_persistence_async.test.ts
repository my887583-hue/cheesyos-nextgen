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
  SCHEMA_VERSION,
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

describe('Phase 3G.2 — Native Semantic Read Persistence & Local Queries (Task 3G.2-01)', () => {
  test('1. GET_TABLES_WITH_SESSIONS_PASS & OCCUPANCY_DERIVATION_PASS — derive AVAILABLE, OCCUPIED, and BILLED correctly', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    const raw = posDb.getRawDb();

    raw.prepare(`
      INSERT INTO pos_tables (id, table_number, section, capacity, is_active, created_at)
      VALUES ('t1', 'T01', 'Indoor', 4, 1, '2026-10-12T10:00:00Z'),
             ('t2', 'T02', 'Indoor', 2, 1, '2026-10-12T10:00:00Z'),
             ('t3', 'T03', 'Rooftop', 6, 1, '2026-10-12T10:00:00Z'),
             ('t4', 'T04', 'Closed Area', 4, 0, '2026-10-12T10:00:00Z');
    `).run();

    raw.prepare(`
      INSERT INTO table_sessions (id, table_id, current_order_id, guest_count, session_status, opened_at, closed_at)
      VALUES ('s1', 't1', 'ord-1', 3, 'open', '2026-10-12T11:00:00Z', NULL),
             ('s2', 't2', 'ord-2', 2, 'billed', '2026-10-12T11:30:00Z', NULL),
             ('s3', 't3', 'ord-old', 4, 'closed', '2026-10-12T09:00:00Z', '2026-10-12T10:00:00Z');
    `).run();

    const tables = await posDb.getTablesWithSessions();

    // Inactive table t4 excluded
    assert.equal(tables.length, 3);

    // T01 -> OCCUPIED
    const t1 = tables.find(t => t.table.id === 't1')!;
    assert.ok(t1.active_session);
    assert.equal(t1.active_session.session_status, 'open');
    assert.equal(posDb.getSchemaVersion(), SCHEMA_VERSION);
    assert.equal(t1.table.capacity, 4);

    // T02 -> BILLED
    const t2 = tables.find(t => t.table.id === 't2')!;
    assert.ok(t2.active_session);
    assert.equal(t2.active_session.session_status, 'billed');

    // T03 -> AVAILABLE
    const t3 = tables.find(t => t.table.id === 't3')!;
    assert.equal(t3.active_session, null);

    posDb.close();
  });

  test('2. MULTIPLE_ACTIVE_SESSIONS_INVARIANT_REJECT — Rejects table with multiple open/billed sessions', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    const raw = posDb.getRawDb();

    raw.prepare(`
      INSERT INTO pos_tables (id, table_number, section, capacity, is_active, created_at)
      VALUES ('t-conflict', 'T99', 'Main', 4, 1, '2026-10-12T10:00:00Z');
    `).run();

    raw.prepare(`
      INSERT INTO table_sessions (id, table_id, guest_count, session_status, opened_at)
      VALUES ('s-c1', 't-conflict', 2, 'open', '2026-10-12T11:00:00Z'),
             ('s-c2', 't-conflict', 3, 'billed', '2026-10-12T11:15:00Z');
    `).run();

    await assert.rejects(
      async () => {
        await posDb.getTablesWithSessions();
      },
      /INVARIANT_VIOLATION.*Multiple active sessions/
    );

    posDb.close();
  });

  test('3. GET_CATALOG_PASS & CATALOG_USES_PAISE_PASS — Returns active catalog with integer Paise prices', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    const raw = posDb.getRawDb();

    raw.prepare(`
      INSERT INTO categories (id, name, slug, display_order, is_active, created_at, updated_at)
      VALUES ('c-active', 'Beverages', 'beverages', 1, 1, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z'),
             ('c-inactive', 'Secret', 'secret', 2, 0, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');
    `).run();

    raw.prepare(`
      INSERT INTO products (id, category_id, name, base_price_paise, is_available, tax_rate, created_at, updated_at)
      VALUES ('p-tea', 'c-active', 'Masala Chai', 4900, 1, 5.0, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z'),
             ('p-soda', 'c-active', 'Out of Stock Soda', 6000, 0, 5.0, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z'),
             ('p-hidden', 'c-inactive', 'Secret Drink', 9900, 1, 5.0, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');
    `).run();

    raw.prepare(`
      INSERT INTO product_variants (id, product_id, variant_name, price_override_paise, is_available, created_at)
      VALUES ('v-large', 'p-tea', 'Large Chai', 6900, 1, '2026-10-12T10:00:00Z'),
             ('v-unavail', 'p-tea', 'XL Chai', 8900, 0, '2026-10-12T10:00:00Z');
    `).run();

    const catalog = await posDb.getCatalog();

    assert.equal(catalog.categories.length, 1);
    assert.equal(catalog.categories[0].id, 'c-active');

    assert.equal(catalog.products.length, 1);
    assert.equal(catalog.products[0].id, 'p-tea');
    assert.equal(catalog.products[0].base_price_paise, 4900);
    assert.equal(Number.isInteger(catalog.products[0].base_price_paise), true);

    assert.equal(catalog.variants.length, 1);
    assert.equal(catalog.variants[0].id, 'v-large');
    assert.equal(catalog.variants[0].price_override_paise, 6900);
    assert.equal(Number.isInteger(catalog.variants[0].price_override_paise!), true);

    posDb.close();
  });

  test('4. GET_ACTIVE_ORDER_FOR_TABLE_PASS & NO_ACTIVE_ORDER_TYPED_RESULT_PASS — Active order hydration with typed null and invariant reject', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    const raw = posDb.getRawDb();

    raw.prepare(`
      INSERT INTO pos_tables (id, table_number, section, capacity, is_active, created_at)
      VALUES ('tbl-1', 'T01', 'Main', 4, 1, '2026-10-12T10:00:00Z'),
             ('tbl-empty', 'T02', 'Main', 4, 1, '2026-10-12T10:00:00Z'),
             ('tbl-no-sess', 'T03', 'Main', 4, 1, '2026-10-12T10:00:00Z');
    `).run();

    raw.prepare(`
      INSERT INTO table_sessions (id, table_id, current_order_id, guest_count, session_status, opened_at)
      VALUES ('sess-1', 'tbl-1', 'ord-1', 2, 'open', '2026-10-12T11:00:00Z'),
             ('sess-empty', 'tbl-empty', NULL, 3, 'open', '2026-10-12T11:05:00Z');
    `).run();

    raw.prepare(`INSERT INTO categories (id, name, slug, created_at, updated_at) VALUES ('c1', 'Main', 'main', 'now', 'now');`).run();
    raw.prepare(`INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at) VALUES ('p1', 'c1', 'Pizza', 15000, 'now', 'now');`).run();

    raw.prepare(`
      INSERT INTO orders (id, display_number, channel, order_type, table_session_id, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at)
      VALUES ('ord-1', 'CB-T01-000001', 'POS', 'DINE_IN', 'sess-1', 'kot_sent', 15000, 750, 0, 0, 15750, '2026-10-12T11:10:00Z', '2026-10-12T11:10:00Z');
    `).run();

    raw.prepare(`
      INSERT INTO order_items (id, order_id, product_id, product_name, unit_price_paise, quantity, tax_rate, discount_amount_paise, line_total_paise, created_at)
      VALUES ('oi-1', 'ord-1', 'p1', 'Pizza', 15000, 1, 5.0, 0, 15000, '2026-10-12T11:10:00Z');
    `).run();

    // 1. Populated active order
    const result = await posDb.getActiveOrderForTable('tbl-1');
    assert.ok(result);
    assert.equal(result.session.id, 'sess-1');
    assert.equal(result.order.id, 'ord-1');
    assert.equal(result.order.grand_total_paise, 15750);
    assert.equal(result.items.length, 1);
    assert.equal(result.items[0].product_name, 'Pizza');

    // 2. Table with session but no order -> typed null
    const resultEmpty = await posDb.getActiveOrderForTable('tbl-empty');
    assert.equal(resultEmpty, null);

    // 3. Table with no session -> typed null
    const resultNoSess = await posDb.getActiveOrderForTable('tbl-no-sess');
    assert.equal(resultNoSess, null);

    // 4. Invariant violation: multiple active orders on session
    raw.prepare(`
      INSERT INTO orders (id, display_number, channel, order_type, table_session_id, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at)
      VALUES ('ord-dup', 'CB-T01-000002', 'POS', 'DINE_IN', 'sess-1', 'draft', 5000, 250, 0, 0, 5250, '2026-10-12T11:12:00Z', '2026-10-12T11:12:00Z');
    `).run();

    await assert.rejects(
      async () => {
        await posDb.getActiveOrderForTable('tbl-1');
      },
      /INVARIANT_VIOLATION.*Multiple active orders/
    );

    posDb.close();
  });

  test('5. GET_BILL_FOR_ORDER_PASS & NO_BILL_TYPED_RESULT_PASS — Reads existing bill or returns typed null', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    const raw = posDb.getRawDb();

    raw.prepare(`
      INSERT INTO orders (id, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at)
      VALUES ('ord-bill-1', 'POS', 'DINE_IN', 'billed', 20000, 1000, 0, 0, 21000, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z'),
             ('ord-no-bill', 'POS', 'DINE_IN', 'draft', 10000, 500, 0, 0, 10500, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');
    `).run();

    raw.prepare(`
      INSERT INTO bills (id, order_id, bill_number, subtotal_paise, cgst_total_paise, sgst_total_paise, discount_total_paise, grand_total_paise, payment_status, finalized_at)
      VALUES ('bill-1', 'ord-bill-1', 'CB-T01-000001', 20000, 500, 500, 0, 21000, 'unpaid', '2026-10-12T10:30:00Z');
    `).run();

    // 1. Existing bill
    const bill = await posDb.getBillForOrder('ord-bill-1');
    assert.ok(bill);
    assert.equal(bill.id, 'bill-1');
    assert.equal(bill.bill_number, 'CB-T01-000001');
    assert.equal(bill.grand_total_paise, 21000);
    assert.equal(bill.payment_status, 'unpaid');

    // 2. Missing bill -> typed null
    const noBill = await posDb.getBillForOrder('ord-no-bill');
    assert.equal(noBill, null);

    posDb.close();
  });
});

describe('Phase 3G.2 — Table Session & Order Status Local Lifecycle (Task 3G.2-02)', () => {
  function seedLifecycleFixtures(posDb: PosLocalDatabase) {
    const raw = posDb.getRawDb();
    raw.prepare(`INSERT OR IGNORE INTO categories (id, name, slug, created_at, updated_at) VALUES ('cat-lc', 'Food', 'food-lc', 'now', 'now')`).run();
    raw.prepare(`INSERT OR IGNORE INTO products (id, category_id, name, base_price_paise, created_at, updated_at) VALUES ('prod-lc1', 'cat-lc', 'Burger', 15000, 'now', 'now')`).run();
    raw.prepare(`INSERT OR IGNORE INTO pos_tables (id, table_number, section, capacity, is_active, created_at) VALUES ('tbl-lc1', 'T-01', 'Indoor', 4, 1, 'now')`).run();
    raw.prepare(`INSERT OR IGNORE INTO pos_tables (id, table_number, section, capacity, is_active, created_at) VALUES ('tbl-lc2', 'T-02', 'Indoor', 2, 1, 'now')`).run();
    raw.prepare(`INSERT OR IGNORE INTO pos_tables (id, table_number, section, capacity, is_active, created_at) VALUES ('tbl-inactive', 'T-99', 'Patio', 4, 0, 'now')`).run();
  }

  test('1. OPEN_TABLE_SESSION_PASS — Successfully opens table session with canonical defaults', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedLifecycleFixtures(posDb);

    const session = await posDb.openTableSession('tbl-lc1', 3);
    assert.ok(session.id);
    assert.equal(session.table_id, 'tbl-lc1');
    assert.equal(session.guest_count, 3);
    assert.equal(session.session_status, 'open');
    assert.equal(session.current_order_id, null);
    assert.equal(session.closed_at, null);
    assert.ok(session.opened_at);

    // Verify derived occupancy is OCCUPIED
    const tables = await posDb.getTablesWithSessions();
    const t1 = tables.find((t) => t.table.id === 'tbl-lc1');
    assert.ok(t1?.active_session);
    assert.equal(t1.active_session.id, session.id);

    posDb.close();
  });

  test('2. OPEN_TABLE_ALREADY_OCCUPIED_REJECT_PASS — Rejects opening session on already occupied table', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedLifecycleFixtures(posDb);

    await posDb.openTableSession('tbl-lc1', 2);

    await assert.rejects(
      async () => {
        await posDb.openTableSession('tbl-lc1', 4);
      },
      /TABLE_ALREADY_OCCUPIED/
    );

    posDb.close();
  });

  test('3. OPEN_INACTIVE_TABLE_REJECT_PASS & INVALID_GUEST_COUNT — Rejects inactive tables or non-positive guest count', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedLifecycleFixtures(posDb);

    // Inactive table
    await assert.rejects(
      async () => {
        await posDb.openTableSession('tbl-inactive', 2);
      },
      /TABLE_INACTIVE/
    );

    // Non-existent table
    await assert.rejects(
      async () => {
        await posDb.openTableSession('tbl-nonexistent', 2);
      },
      /TABLE_NOT_FOUND/
    );

    // Invalid guest counts
    await assert.rejects(
      async () => {
        await posDb.openTableSession('tbl-lc2', 0);
      },
      /INVALID_GUEST_COUNT/
    );
    await assert.rejects(
      async () => {
        await posDb.openTableSession('tbl-lc2', -1);
      },
      /INVALID_GUEST_COUNT/
    );

    posDb.close();
  });

  test('4. KOT_AND_ORDER_STATUS_ATOMIC_PASS — KOT dispatch persists items and advances orders.status to kot_sent atomically', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedLifecycleFixtures(posDb);
    const now = new Date().toISOString();

    const session = await posDb.openTableSession('tbl-lc1', 2);

    // Create order with pending status
    await posDb.saveOrderAggregate(
      {
        id: 'ord-kot-1',
        channel: 'POS',
        order_type: 'DINE_IN',
        table_session_id: session.id,
        status: 'pending',
        subtotal: 150,
        tax_total: 7.5,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 157.5,
        created_at: now,
        updated_at: now,
      },
      [
        {
          id: 'item-kot-1',
          order_id: 'ord-kot-1',
          product_id: 'prod-lc1',
          product_name: 'Burger',
          unit_price: 150,
          quantity: 1,
          tax_rate: 5,
          discount_amount: 0,
          line_total: 150,
          created_at: now,
        },
      ]
    );

    // Dispatch KOT
    await posDb.saveKotAggregate(
      {
        id: 'kot-test-1',
        order_id: 'ord-kot-1',
        kot_number: 1,
        status: 'printed',
        printed_at: now,
      },
      [
        {
          id: 'ki-test-1',
          kot_id: 'kot-test-1',
          product_id: 'prod-lc1',
          product_name: 'Burger',
          quantity: 1,
        },
      ]
    );

    // Verify orders.status is now 'kot_sent'
    const rawOrder = posDb.getRawDb().prepare('SELECT status FROM orders WHERE id = ?').get('ord-kot-1') as { status: string };
    assert.equal(rawOrder.status, 'kot_sent');

    posDb.close();
  });

  test('5. KOT_FAILURE_ROLLBACK_STATUS_PASS — KOT failure rolls back both KOT and order status', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedLifecycleFixtures(posDb);
    const now = new Date().toISOString();

    // Create order with pending status
    await posDb.saveOrderAggregate(
      {
        id: 'ord-kot-fail',
        channel: 'POS',
        order_type: 'DINE_IN',
        status: 'pending',
        subtotal: 150,
        tax_total: 7.5,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 157.5,
        created_at: now,
        updated_at: now,
      },
      []
    );

    // Attempt KOT dispatch with invalid foreign key product
    await assert.rejects(
      async () => {
        await posDb.saveKotAggregate(
          {
            id: 'kot-fail-1',
            order_id: 'ord-kot-fail',
            kot_number: 1,
            status: 'printed',
            printed_at: now,
          },
          [
            {
              id: 'ki-fail-1',
              kot_id: 'kot-fail-1',
              product_id: 'prod-nonexistent', // FOREIGN KEY FAIL
              product_name: 'Ghost',
              quantity: 1,
            },
          ]
        );
      }
    );

    // Verify orders.status remained 'pending'
    const rawOrder = posDb.getRawDb().prepare('SELECT status FROM orders WHERE id = ?').get('ord-kot-fail') as { status: string };
    assert.equal(rawOrder.status, 'pending');

    // Verify no orphaned KOT header
    const rawKot = posDb.getRawDb().prepare('SELECT id FROM pos_kots WHERE id = ?').get('kot-fail-1');
    assert.equal(rawKot, undefined);

    posDb.close();
  });

  test('6. BILL_AND_ORDER_STATUS_ATOMIC_PASS — Bill finalization saves bill and advances orders.status to billed atomically', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedLifecycleFixtures(posDb);
    const now = new Date().toISOString();

    await posDb.setDeviceConfig({
      device_id: 'dev-001',
      terminal_code: 'T01',
      device_name: 'Counter',
    });

    const session = await posDb.openTableSession('tbl-lc1', 2);

    await posDb.saveOrderAggregate(
      {
        id: 'ord-bill-test',
        channel: 'POS',
        order_type: 'DINE_IN',
        table_session_id: session.id,
        status: 'kot_sent',
        subtotal: 150,
        tax_total: 7.5,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 157.5,
        created_at: now,
        updated_at: now,
      },
      []
    );

    // Save Bill with sequence
    const billRes = await posDb.saveBillWithSequence({
      id: 'bill-test-1',
      order_id: 'ord-bill-test',
      bill_number: 'PENDING',
      subtotal: 150,
      cgst_total: 3.75,
      sgst_total: 3.75,
      discount_total: 0,
      grand_total: 157.5,
      payment_status: 'unpaid',
      finalized_at: now,
    });

    assert.equal(billRes.bill.bill_number, 'CB-T01-000001');

    // Verify orders.status is now 'billed'
    const rawOrder = posDb.getRawDb().prepare('SELECT status FROM orders WHERE id = ?').get('ord-bill-test') as { status: string };
    assert.equal(rawOrder.status, 'billed');

    // Verify table session status is 'billed' and derived occupancy is BILLED
    const rawSession = posDb.getRawDb().prepare('SELECT session_status FROM table_sessions WHERE id = ?').get(session.id) as { session_status: string };
    assert.equal(rawSession.session_status, 'billed');

    posDb.close();
  });

  test('7. BILL_FAILURE_ROLLBACK_STATUS_PASS — Bill failure rolls back bill and preserves order status', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedLifecycleFixtures(posDb);
    const now = new Date().toISOString();

    await posDb.setDeviceConfig({
      device_id: 'dev-001',
      terminal_code: 'T01',
      device_name: 'Counter',
    });

    await posDb.saveOrderAggregate(
      {
        id: 'ord-bill-fail',
        channel: 'POS',
        order_type: 'DINE_IN',
        status: 'kot_sent',
        subtotal: 150,
        tax_total: 7.5,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 157.5,
        created_at: now,
        updated_at: now,
      },
      []
    );

    // Attempt bill finalization with conflicting bill number
    await assert.rejects(
      async () => {
        await posDb.saveBillWithSequence({
          id: 'bill-fail-1',
          order_id: 'ord-bill-fail',
          bill_number: 'CB-CONFLICT-999', // Conflicting non-placeholder bill number
          subtotal: 150,
          cgst_total: 3.75,
          sgst_total: 3.75,
          discount_total: 0,
          grand_total: 157.5,
          payment_status: 'unpaid',
          finalized_at: now,
        });
      },
      /BILL_NUMBER_CONFLICT/
    );

    // Verify order status remained 'kot_sent'
    const rawOrder = posDb.getRawDb().prepare('SELECT status FROM orders WHERE id = ?').get('ord-bill-fail') as { status: string };
    assert.equal(rawOrder.status, 'kot_sent');

    posDb.close();
  });

  test('8. PAYMENT_AND_ORDER_STATUS_ATOMIC_PASS — Payment settlement updates bill and advances orders.status to settled atomically', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedLifecycleFixtures(posDb);
    const now = new Date().toISOString();

    await posDb.setDeviceConfig({
      device_id: 'dev-001',
      terminal_code: 'T01',
      device_name: 'Counter',
    });

    await posDb.saveOrderAggregate(
      {
        id: 'ord-pay-test',
        channel: 'POS',
        order_type: 'DINE_IN',
        status: 'kot_sent',
        subtotal: 150,
        tax_total: 7.5,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 157.5,
        created_at: now,
        updated_at: now,
      },
      []
    );

    const billRes = await posDb.saveBillWithSequence({
      id: 'bill-pay-test',
      order_id: 'ord-pay-test',
      bill_number: 'PENDING',
      subtotal: 150,
      cgst_total: 3.75,
      sgst_total: 3.75,
      discount_total: 0,
      grand_total: 157.5,
      payment_status: 'unpaid',
      finalized_at: now,
    });

    // Settle Payment
    await posDb.savePayment(
      {
        id: 'pay-test-1',
        bill_id: 'bill-pay-test',
        order_id: 'ord-pay-test',
        payment_mode: 'CASH',
        amount_paid: 157.5,
        confirmed_at: now,
      },
      {
        ...billRes.bill,
        payment_status: 'paid',
      }
    );

    // Verify orders.status is now 'settled'
    const rawOrder = posDb.getRawDb().prepare('SELECT status FROM orders WHERE id = ?').get('ord-pay-test') as { status: string };
    assert.equal(rawOrder.status, 'settled');

    // Verify bill payment status is 'paid'
    const rawBill = posDb.getRawDb().prepare('SELECT payment_status FROM bills WHERE id = ?').get('bill-pay-test') as { payment_status: string };
    assert.equal(rawBill.payment_status, 'paid');

    posDb.close();
  });

  test('9. PAYMENT_FAILURE_ROLLBACK_STATUS_PASS — Payment failure rolls back payment and order status remains billed', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedLifecycleFixtures(posDb);
    const now = new Date().toISOString();

    await posDb.setDeviceConfig({
      device_id: 'dev-001',
      terminal_code: 'T01',
      device_name: 'Counter',
    });

    await posDb.saveOrderAggregate(
      {
        id: 'ord-pay-fail',
        channel: 'POS',
        order_type: 'DINE_IN',
        status: 'kot_sent',
        subtotal: 150,
        tax_total: 7.5,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 157.5,
        created_at: now,
        updated_at: now,
      },
      []
    );

    const billRes = await posDb.saveBillWithSequence({
      id: 'bill-pay-fail',
      order_id: 'ord-pay-fail',
      bill_number: 'PENDING',
      subtotal: 150,
      cgst_total: 3.75,
      sgst_total: 3.75,
      discount_total: 0,
      grand_total: 157.5,
      payment_status: 'unpaid',
      finalized_at: now,
    });

    // Attempt invalid payment with 0 amount (violates amount_paid_paise > 0 CHECK constraint)
    await assert.rejects(
      async () => {
        await posDb.savePayment(
          {
            id: 'pay-fail-1',
            bill_id: 'bill-pay-fail',
            order_id: 'ord-pay-fail',
            payment_mode: 'CASH',
            amount_paid: 0, // CHECK constraint failure
            confirmed_at: now,
          },
          {
            ...billRes.bill,
            payment_status: 'paid',
          }
        );
      }
    );

    // Verify order status remained 'billed'
    const rawOrder = posDb.getRawDb().prepare('SELECT status FROM orders WHERE id = ?').get('ord-pay-fail') as { status: string };
    assert.equal(rawOrder.status, 'billed');

    // Verify bill payment status remained 'unpaid'
    const rawBill = posDb.getRawDb().prepare('SELECT payment_status FROM bills WHERE id = ?').get('bill-pay-fail') as { payment_status: string };
    assert.equal(rawBill.payment_status, 'unpaid');

    posDb.close();
  });

  test('10, 11, 12. CLOSE_TABLE_SESSION_PASS, CLOSE_UNSETTLED_ORDER_REJECT_PASS & CLOSE_SESSION_RELEASES_TABLE_PASS', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedLifecycleFixtures(posDb);
    const now = new Date().toISOString();

    await posDb.setDeviceConfig({
      device_id: 'dev-001',
      terminal_code: 'T01',
      device_name: 'Counter',
    });

    const session = await posDb.openTableSession('tbl-lc1', 2);

    await posDb.saveOrderAggregate(
      {
        id: 'ord-close-flow',
        channel: 'POS',
        order_type: 'DINE_IN',
        table_session_id: session.id,
        status: 'kot_sent',
        subtotal: 150,
        tax_total: 7.5,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 157.5,
        created_at: now,
        updated_at: now,
      },
      []
    );

    // 1. Attempt close while order is kot_sent -> REJECT
    await assert.rejects(
      async () => {
        await posDb.closeTableSession(session.id, 'ord-close-flow');
      },
      /ORDER_NOT_SETTLED/
    );

    // Advance to billed
    const billRes = await posDb.saveBillWithSequence({
      id: 'bill-close-flow',
      order_id: 'ord-close-flow',
      bill_number: 'PENDING',
      subtotal: 150,
      cgst_total: 3.75,
      sgst_total: 3.75,
      discount_total: 0,
      grand_total: 157.5,
      payment_status: 'unpaid',
      finalized_at: now,
    });

    // 2. Attempt close while order is billed -> REJECT
    await assert.rejects(
      async () => {
        await posDb.closeTableSession(session.id, 'ord-close-flow');
      },
      /ORDER_NOT_SETTLED/
    );

    // Settle payment
    await posDb.savePayment(
      {
        id: 'pay-close-flow',
        bill_id: 'bill-close-flow',
        order_id: 'ord-close-flow',
        payment_mode: 'CASH',
        amount_paid: 157.5,
        confirmed_at: now,
      },
      {
        ...billRes.bill,
        payment_status: 'paid',
      }
    );

    // 3. Attempt close with unlinked order -> REJECT
    await assert.rejects(
      async () => {
        await posDb.closeTableSession(session.id, 'ord-nonexistent');
      },
      /ORDER_NOT_FOUND/
    );

    // 4. Successful close
    await posDb.closeTableSession(session.id, 'ord-close-flow');

    // Verify session is closed with closed_at timestamp
    const rawSession = posDb.getRawDb().prepare('SELECT session_status, closed_at FROM table_sessions WHERE id = ?').get(session.id) as { session_status: string; closed_at: string | null };
    assert.equal(rawSession.session_status, 'closed');
    assert.ok(rawSession.closed_at);

    // Verify orders.status is closed
    const rawOrder = posDb.getRawDb().prepare('SELECT status FROM orders WHERE id = ?').get('ord-close-flow') as { status: string };
    assert.equal(rawOrder.status, 'closed');

    // 5. Verify table is released and derived occupancy is AVAILABLE
    const tables = await posDb.getTablesWithSessions();
    const t1 = tables.find((t) => t.table.id === 'tbl-lc1');
    assert.equal(t1?.active_session, null);

    // 6. Attempting close again on closed session -> REJECT
    await assert.rejects(
      async () => {
        await posDb.closeTableSession(session.id, 'ord-close-flow');
      },
      /SESSION_ALREADY_CLOSED/
    );

    posDb.close();
  });

  test('13. NO_DUPLICATE_ACTIVE_SESSION_PASS — Re-opening table with existing active session is strictly blocked', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedLifecycleFixtures(posDb);

    await posDb.openTableSession('tbl-lc1', 2);

    await assert.rejects(
      async () => {
        await posDb.openTableSession('tbl-lc1', 3);
      },
      /TABLE_ALREADY_OCCUPIED/
    );

    posDb.close();
  });

  test('14. ORDER_STATUS_REGRESSION_REJECT_PASS — Preserves lifecycle progression & rejects invalid status regression', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedLifecycleFixtures(posDb);
    const now = new Date().toISOString();

    await posDb.setDeviceConfig({
      device_id: 'dev-001',
      terminal_code: 'T01',
      device_name: 'Counter',
    });

    // Create cancelled order
    posDb.getRawDb().prepare(`
      INSERT INTO orders (id, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at)
      VALUES ('ord-cancelled', 'POS', 'DINE_IN', 'cancelled', 10000, 500, 0, 0, 10500, 'now', 'now')
    `).run();

    // 1. KOT dispatch on cancelled order -> REJECT
    await assert.rejects(
      async () => {
        await posDb.saveKotAggregate(
          {
            id: 'kot-reg-1',
            order_id: 'ord-cancelled',
            kot_number: 1,
            status: 'printed',
            printed_at: now,
          },
          []
        );
      },
      /ORDER_STATUS_INVALID/
    );

    // 2. Bill finalization on cancelled order -> REJECT
    await assert.rejects(
      async () => {
        await posDb.saveBillWithSequence({
          id: 'bill-reg-1',
          order_id: 'ord-cancelled',
          bill_number: 'PENDING',
          subtotal: 100,
          cgst_total: 2.5,
          sgst_total: 2.5,
          discount_total: 0,
          grand_total: 105,
          payment_status: 'unpaid',
          finalized_at: now,
        });
      },
      /ORDER_STATUS_INVALID/
    );

    // 3. Payment on cancelled order -> REJECT
    await assert.rejects(
      async () => {
        await posDb.savePayment(
          {
            id: 'pay-reg-1',
            bill_id: 'bill-any',
            order_id: 'ord-cancelled',
            payment_mode: 'CASH',
            amount_paid: 105,
            confirmed_at: now,
          },
          {
            id: 'bill-any',
            order_id: 'ord-cancelled',
            bill_number: 'B-ANY',
            subtotal: 100,
            cgst_total: 2.5,
            sgst_total: 2.5,
            discount_total: 0,
            grand_total: 105,
            payment_status: 'paid',
            finalized_at: now,
          }
        );
      },
      /ORDER_STATUS_INVALID/
    );

    // 4. Finalizing bill on settled order -> REJECT regression
    posDb.getRawDb().prepare(`
      INSERT INTO orders (id, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at)
      VALUES ('ord-settled-reg', 'POS', 'DINE_IN', 'settled', 10000, 500, 0, 0, 10500, 'now', 'now')
    `).run();

    await assert.rejects(
      async () => {
        await posDb.saveBillWithSequence({
          id: 'bill-reg-settled',
          order_id: 'ord-settled-reg',
          bill_number: 'PENDING',
          subtotal: 100,
          cgst_total: 2.5,
          sgst_total: 2.5,
          discount_total: 0,
          grand_total: 105,
          payment_status: 'unpaid',
          finalized_at: now,
        });
      },
      /ORDER_STATUS_REGRESSION/
    );

    posDb.close();
  });

  test('15. LOCAL_TABLE_SESSION_OUTBOX_LIFECYCLE — open, billed, close emit outbox & open precedes order', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    seedLifecycleFixtures(posDb);
    const now = new Date().toISOString();

    await posDb.setDeviceConfig({
      device_id: 'dev-001',
      terminal_code: 'T01',
      device_name: 'Counter',
    });

    // 1. LOCAL_OPEN_SESSION_OUTBOX_ATOMIC_PASS
    const session = await posDb.openTableSession('tbl-lc1', 3);
    assert.ok(session.id);
    assert.equal(session.session_status, 'open');

    let outbox = await posDb.getPendingOutbox(10);
    assert.equal(outbox.length, 1);
    assert.equal(outbox[0].entity_type, 'table_sessions');
    assert.equal(outbox[0].entity_id, session.id);
    assert.equal(outbox[0].operation, 'INSERT');
    const openPayload = JSON.parse(outbox[0].payload_json);
    assert.equal(openPayload.session.id, session.id);
    assert.equal(openPayload.session.session_status, 'open');
    assert.equal(openPayload.session.guest_count, 3);
    const sessionOutboxSeq = outbox[0].seq;

    // 2. OPEN_OUTBOX_PRECEDES_ORDER_OUTBOX_PASS
    const { order, items } = createTestOrder('ord-sess-1');
    order.table_session_id = session.id;
    items[0].product_id = 'prod-lc1';
    await posDb.saveOrderAggregate(order, items);

    outbox = await posDb.getPendingOutbox(10);
    assert.equal(outbox.length, 2);
    assert.equal(outbox[1].entity_type, 'orders');
    assert.equal(outbox[1].entity_id, 'ord-sess-1');
    const orderOutboxSeq = outbox[1].seq;
    assert.ok(sessionOutboxSeq < orderOutboxSeq, `Session seq (${sessionOutboxSeq}) must precede order seq (${orderOutboxSeq})`);

    // 3. Dispatch KOT
    await posDb.saveKotAggregate(
      {
        id: 'kot-sess-1',
        order_id: 'ord-sess-1',
        kot_number: 1,
        status: 'printed',
        printed_at: now,
      },
      [
        {
          id: 'kitem-sess-1',
          kot_id: 'kot-sess-1',
          product_id: 'prod-lc1',
          product_name: 'Burger',
          quantity: 1,
        },
      ]
    );

    // 4. LOCAL_BILLED_SESSION_OUTBOX_ATOMIC_PASS
    await posDb.saveBillWithSequence({
      id: 'bill-sess-1',
      order_id: 'ord-sess-1',
      bill_number: 'PENDING',
      subtotal: 100,
      cgst_total: 2.5,
      sgst_total: 2.5,
      discount_total: 0,
      grand_total: 105,
      payment_status: 'unpaid',
      finalized_at: now,
    });

    outbox = await posDb.getPendingOutbox(10);
    const billedSessionOutbox = outbox.find((o) => o.entity_type === 'table_sessions' && o.operation === 'UPDATE');
    assert.ok(billedSessionOutbox, 'Billed table session update outbox entry must exist');
    const billedPayload = JSON.parse(billedSessionOutbox!.payload_json);
    assert.equal(billedPayload.session.id, session.id);
    assert.equal(billedPayload.session.session_status, 'billed');

    // 5. Settle payment
    await posDb.savePayment(
      {
        id: 'pay-sess-1',
        bill_id: 'bill-sess-1',
        order_id: 'ord-sess-1',
        payment_mode: 'CASH',
        amount_paid: 105,
        confirmed_at: now,
      },
      {
        id: 'bill-sess-1',
        order_id: 'ord-sess-1',
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

    // 6. LOCAL_CLOSE_SESSION_OUTBOX_ATOMIC_PASS
    await posDb.closeTableSession(session.id, 'ord-sess-1');

    outbox = await posDb.getPendingOutbox(10);
    const sessionOutboxEntries = outbox.filter((o) => o.entity_type === 'table_sessions');
    assert.equal(sessionOutboxEntries.length, 3, 'Must have 3 session outbox entries: open, billed, closed');

    const closedSessionOutbox = sessionOutboxEntries[2];
    assert.equal(closedSessionOutbox.operation, 'UPDATE');
    const closedPayload = JSON.parse(closedSessionOutbox.payload_json);
    assert.equal(closedPayload.session.id, session.id);
    assert.equal(closedPayload.session.session_status, 'closed');
    assert.equal(closedPayload.order_id, 'ord-sess-1');

    posDb.close();
  });
});

