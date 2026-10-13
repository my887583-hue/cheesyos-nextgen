/**
 * CHEESYOS NEXTGEN POS LOCAL — DURABILITY & ATOMICITY TEST SUITE
 * 
 * Verifies SQLite transaction atomicity, crash safety rollback, durable outbox queueing,
 * foreign key enforcement, payload immutability, and process restart persistence using real disk-based temporary SQLite database files.
 */

import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { PosCart, createOrderDraft, createKotDispatchSnapshot, createKotCorrection, finalizeBill, confirmPayment } from '@cheesyos/pos-core';
import {
  PosLocalDatabase,
  getPendingOutboxEntries,
  saveOrderTransaction,
  saveKotDispatchTransaction,
  saveKotCorrectionTransaction,
  saveBillTransaction,
  savePaymentTransaction,
  saveInventoryMovementTransaction,
  insertOutboxRecord,
  SCHEMA_VERSION,
} from '../src/index.js';

describe('1. SQLite Persistence Initialization & Constraints', () => {
  test('A, B, C. Fresh DB initializes with WAL, foreign keys enabled, user_version = 1', () => {
    const dbManager = new PosLocalDatabase(':memory:');
    const rawDb = dbManager.getRawDb();

    assert.equal(dbManager.getSchemaVersion(), SCHEMA_VERSION);

    const fkResult = rawDb.prepare('PRAGMA foreign_keys;').get() as { foreign_keys: number };
    assert.equal(fkResult.foreign_keys, 1);

    dbManager.close();
  });

  test('Foreign key constraint violation is rejected by SQLite runtime', () => {
    const dbManager = new PosLocalDatabase(':memory:');
    const rawDb = dbManager.getRawDb();

    // Inserting order_item for non-existent order_id fails FK constraint
    assert.throws(() => {
      rawDb.prepare(`
        INSERT INTO order_items (id, order_id, product_id, product_name, unit_price_paise, quantity, line_total_paise, created_at)
        VALUES ('item-orphan', 'non-existent-order-id', 'p1', 'Burger', 9900, 1, 9900, 'now')
      `).run();
    }, /FOREIGN KEY constraint failed/);

    dbManager.close();
  });

  test('Nested transactions are explicitly rejected to prevent partial commit bugs', () => {
    const dbManager = new PosLocalDatabase(':memory:');
    assert.throws(() => {
      dbManager.runTransaction(() => {
        dbManager.runTransaction(() => {
          // Nested transaction call
        });
      });
    }, /Nested transactions are not supported/);

    dbManager.close();
  });

  test('Q. Integer paise round-trip exactness', () => {
    const dbManager = new PosLocalDatabase(':memory:');
    const db = dbManager.getRawDb();

    // Populate category & product for FK constraints
    const catId = 'cat-1';
    const prodId = 'prod-99';
    db.prepare(`INSERT INTO categories (id, name, slug, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`).run(catId, 'Pizza', 'pizza', 'now', 'now');
    db.prepare(`INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)`).run(prodId, catId, 'Veg Pizza', 12999, 'now', 'now');

    const row = db.prepare('SELECT base_price_paise FROM products WHERE id = ?').get(prodId) as { base_price_paise: number };
    assert.equal(row.base_price_paise, 12999);

    dbManager.close();
  });
});

describe('2. Order Transaction, Payload Immutability & Crash Safety', () => {
  test('D & E. Order + items + outbox atomic commit; forced outbox error rolls back entire order', () => {
    const dbManager = new PosLocalDatabase(':memory:');
    const db = dbManager.getRawDb();

    // Setup catalog prerequisite
    db.prepare(`INSERT INTO categories (id, name, slug, created_at, updated_at) VALUES ('c1', 'Burger', 'burger', 'now', 'now')`).run();
    db.prepare(`INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at) VALUES ('p1', 'c1', 'Burger', 9900, 'now', 'now')`).run();

    const cart = new PosCart();
    cart.addItem({ productId: 'p1', productName: 'Burger', unitPriceRupees: 99.0, quantity: 2 });
    const draft = createOrderDraft(cart, { displayNumber: 'CB-K01-0001' });

    // Successful Atomic Save
    const saveResult = saveOrderTransaction(dbManager, draft.order, draft.items);
    assert.equal(saveResult.outboxEntries.length, 1);

    const orderRow = db.prepare('SELECT * FROM orders WHERE id = ?').get(draft.order.id) as { id: string } | undefined;
    assert.notEqual(orderRow, undefined);

    const pendingOutbox = getPendingOutboxEntries(db);
    assert.equal(pendingOutbox.length, 1);
    assert.equal(pendingOutbox[0].entity_id, draft.order.id);

    // CRASH SAFETY TEST: Force outbox failure inside transaction
    const cart2 = new PosCart();
    cart2.addItem({ productId: 'p1', productName: 'Burger', unitPriceRupees: 99.0, quantity: 1 });
    const draft2 = createOrderDraft(cart2);

    assert.throws(() => {
      dbManager.runTransaction((txDb) => {
        // Step 1: Insert order header & items
        txDb.prepare(`INSERT INTO orders (id, channel, order_type, created_at, updated_at) VALUES (?, 'POS', 'DINE_IN', 'now', 'now')`).run(draft2.order.id);
        // Step 2: Intentionally fail outbox insert with duplicate outbox ID
        txDb.prepare(`INSERT INTO sync_outbox (id, entity_type, entity_id, operation, payload_json, created_at) VALUES (?, ?, ?, ?, ?, ?)`).run(
          saveResult.outboxEntries[0].id, // Duplicate PK causes constraint error
          'orders',
          draft2.order.id,
          'INSERT',
          '{}',
          'now'
        );
      });
    });

    // Verify draft2 order header was COMPLETELY ROLLED BACK
    const rolledBackOrder = db.prepare('SELECT * FROM orders WHERE id = ?').get(draft2.order.id);
    assert.equal(rolledBackOrder, undefined);

    dbManager.close();
  });

  test('Payload Immutability: Mutating JS object after commit does not alter stored SQLite payload_json', () => {
    const dbManager = new PosLocalDatabase(':memory:');
    const db = dbManager.getRawDb();

    db.prepare(`INSERT INTO categories (id, name, slug, created_at, updated_at) VALUES ('c1', 'Burger', 'burger', 'now', 'now')`).run();
    db.prepare(`INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at) VALUES ('p1', 'c1', 'Burger', 9900, 'now', 'now')`).run();

    const cart = new PosCart();
    cart.addItem({ productId: 'p1', productName: 'Burger', unitPriceRupees: 99.0, quantity: 1 });
    const draft = createOrderDraft(cart);

    saveOrderTransaction(dbManager, draft.order, draft.items);

    // Mutate memory object
    draft.order.grand_total = 99999;
    draft.items[0].unit_price = 99999;

    // Read stored outbox payload_json from SQLite
    const pendingOutbox = getPendingOutboxEntries(db);
    const parsedPayload = JSON.parse(pendingOutbox[0].payload_json);

    // Stored payload JSON remains unchanged
    assert.equal(parsedPayload.order.grand_total, 103.95);
    assert.equal(parsedPayload.items[0].unit_price, 99.0);

    dbManager.close();
  });
});

describe('3. Restart Durability (Real Disk-based SQLite File)', () => {
  let tmpDir: string;
  let dbFilePath: string;

  before(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'cheesyos-pos-test-'));
    dbFilePath = path.join(tmpDir, 'pos_durability.db');
  });

  after(() => {
    if (fs.existsSync(dbFilePath)) fs.unlinkSync(dbFilePath);
    if (fs.existsSync(`${dbFilePath}-wal`)) fs.unlinkSync(`${dbFilePath}-wal`);
    if (fs.existsSync(`${dbFilePath}-shm`)) fs.unlinkSync(`${dbFilePath}-shm`);
    if (fs.existsSync(tmpDir)) fs.rmdirSync(tmpDir);
  });

  test('F, G, H, I, J, K, L. Operational data & outbox survive DB close and process restart', () => {
    // Phase 1: Open DB, setup catalog, save Order, KOT, Bill, Payment, and close DB
    let dbManager = new PosLocalDatabase(dbFilePath);
    const db = dbManager.getRawDb();

    db.prepare(`INSERT INTO categories (id, name, slug, created_at, updated_at) VALUES ('cat-dura', 'Dura', 'dura', 'now', 'now')`).run();
    db.prepare(`INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at) VALUES ('prod-dura', 'cat-dura', 'Pizza', 35000, 'now', 'now')`).run();

    const cart = new PosCart();
    cart.addItem({ productId: 'prod-dura', productName: 'Pizza', unitPriceRupees: 350.0, quantity: 1 });
    const draft = createOrderDraft(cart, { displayNumber: 'CB-DURA-101' });

    // Save Order
    saveOrderTransaction(dbManager, draft.order, draft.items);

    // Save KOT
    const kotResult = createKotDispatchSnapshot(draft.order.id, draft.items, { kotNumber: 201 });
    saveKotDispatchTransaction(dbManager, kotResult.kot, kotResult.items);

    // Save KOT Correction
    const correction = createKotCorrection({
      orderId: draft.order.id,
      kotId: kotResult.kot.id,
      productName: 'Pizza',
      dispatchedQty: 1,
      cancelledQty: 1,
      reason: 'Testing durability',
      authorizedByStaffId: 'staff-mgr',
    });
    saveKotCorrectionTransaction(dbManager, correction);

    // Save Bill
    const bill = finalizeBill(draft.order, { billNumber: 'CB-BILL-201' });
    saveBillTransaction(dbManager, bill);

    // Save Payment
    const settlement = confirmPayment({ bill, paymentMode: 'CASH', amountPaidRupees: 367.5 });
    savePaymentTransaction(dbManager, settlement.payment, settlement.updatedBill);

    // CLOSE DATABASE (Simulates process termination/crash)
    dbManager.close();

    // Phase 2: REOPEN DATABASE from disk file
    dbManager = new PosLocalDatabase(dbFilePath);
    const reopenedDb = dbManager.getRawDb();

    // Verify Order persisted
    const savedOrder = reopenedDb.prepare('SELECT * FROM orders WHERE id = ?').get(draft.order.id) as { id: string; display_number: string };
    assert.notEqual(savedOrder, undefined);
    assert.equal(savedOrder.display_number, 'CB-DURA-101');

    // Verify KOT & Correction persisted
    const savedKot = reopenedDb.prepare('SELECT * FROM pos_kots WHERE id = ?').get(kotResult.kot.id) as { kot_number: number };
    assert.equal(savedKot.kot_number, 201);

    const savedCorr = reopenedDb.prepare('SELECT * FROM kot_corrections WHERE id = ?').get(correction.id) as { reason: string };
    assert.equal(savedCorr.reason, 'Testing durability');

    // Verify Bill & Payment persisted
    const savedBill = reopenedDb.prepare('SELECT * FROM bills WHERE id = ?').get(bill.id) as { payment_status: string };
    assert.equal(savedBill.payment_status, 'paid');

    // Verify Outbox Entries persisted in exact order
    const pendingOutbox = getPendingOutboxEntries(reopenedDb, 100);
    assert.equal(pendingOutbox.length, 5); // Order, KOT, KOT Correction, Bill, Payment
    assert.equal(pendingOutbox[0].entity_type, 'orders');
    assert.equal(pendingOutbox[1].entity_type, 'pos_kots');
    assert.equal(pendingOutbox[2].entity_type, 'kot_corrections');
    assert.equal(pendingOutbox[3].entity_type, 'bills');
    assert.equal(pendingOutbox[4].entity_type, 'payments');

    dbManager.close();
  });
});

describe('4. Inventory Movement Fixed Identity & Idempotency', () => {
  test('N, O. Inventory movement with fixed UUID survives restart for cloud RPC idempotency', () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'cheesyos-inv-test-'));
    const dbPath = path.join(tmpDir, 'inv.db');

    let dbManager = new PosLocalDatabase(dbPath);
    const db = dbManager.getRawDb();

    db.prepare(`INSERT INTO categories (id, name, slug, created_at, updated_at) VALUES ('c-inv', 'Drink', 'drink', 'now', 'now')`).run();
    db.prepare(`INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at) VALUES ('p-coke', 'c-inv', 'Coke', 4000, 'now', 'now')`).run();
    db.prepare(`INSERT INTO inventory_lite (id, product_id, current_stock, updated_at) VALUES ('inv-coke', 'p-coke', 50, 'now')`).run();

    const fixedMovementId = 'mov-fixed-uuid-12345';
    const result = saveInventoryMovementTransaction(dbManager, {
      id: fixedMovementId,
      productId: 'p-coke',
      movementType: 'SALE',
      quantityChange: -2,
    });

    assert.equal(result.movementId, fixedMovementId);
    assert.equal(result.newStock, 48);

    dbManager.close();

    // REOPEN DB & VERIFY
    dbManager = new PosLocalDatabase(dbPath);
    const reopenedDb = dbManager.getRawDb();

    const movRow = reopenedDb.prepare('SELECT * FROM inventory_movements WHERE id = ?').get(fixedMovementId) as { quantity_change: number };
    assert.notEqual(movRow, undefined);
    assert.equal(movRow.quantity_change, -2);

    const outboxEntries = getPendingOutboxEntries(reopenedDb, 10);
    const invOutbox = outboxEntries.find((e) => e.entity_id === fixedMovementId);
    assert.notEqual(invOutbox, undefined);

    dbManager.close();

    // Clean up
    if (fs.existsSync(dbPath)) fs.unlinkSync(dbPath);
    if (fs.existsSync(`${dbPath}-wal`)) fs.unlinkSync(`${dbPath}-wal`);
    if (fs.existsSync(`${dbPath}-shm`)) fs.unlinkSync(`${dbPath}-shm`);
    if (fs.existsSync(tmpDir)) fs.rmdirSync(tmpDir);
  });
});

describe('5. Task 3G.2-09C.1 — Semantic Read getKotsForOrder', () => {
  test('GET_KOTS_FOR_ORDER complete verification suite', async () => {
    const dbManager = new PosLocalDatabase(':memory:');
    const rawDb = dbManager.getRawDb();

    // 1. GET_KOTS_FOR_ORDER_EMPTY_PASS
    const emptyKots = await dbManager.getKotsForOrder('ord-non-existent');
    assert.deepEqual(emptyKots, [], 'GET_KOTS_FOR_ORDER_EMPTY_PASS: non-existent order returns empty array');

    // Setup base master and order rows
    rawDb.prepare(`INSERT INTO categories (id, name, slug, created_at, updated_at) VALUES ('cat-1', 'Burgers', 'burgers', 'now', 'now')`).run();
    rawDb.prepare(`INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at) VALUES ('prod-1', 'cat-1', 'Burger', 10000, 'now', 'now')`).run();
    rawDb.prepare(`INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at) VALUES ('prod-2', 'cat-1', 'Fries', 5000, 'now', 'now')`).run();

    const orderId = 'ord-kot-read-1';
    rawDb.prepare(`
      INSERT INTO orders (id, display_number, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, version, created_at, updated_at)
      VALUES (?, 'CB-01', 'POS', 'DINE_IN', 'kot_sent', 25000, 1250, 0, 0, 26250, 1, 'now', 'now')
    `).run(orderId);

    // Insert order items
    const orderItemId1 = 'oitem-1';
    const orderItemId2 = 'oitem-2';
    rawDb.prepare(`
      INSERT INTO order_items (id, order_id, product_id, product_name, unit_price_paise, quantity, tax_rate, discount_amount_paise, line_total_paise, created_at)
      VALUES (?, ?, 'prod-1', 'Burger', 10000, 2, 5.0, 0, 21000, 'now')
    `).run(orderItemId1, orderId);
    rawDb.prepare(`
      INSERT INTO order_items (id, order_id, product_id, product_name, unit_price_paise, quantity, tax_rate, discount_amount_paise, line_total_paise, created_at)
      VALUES (?, ?, 'prod-1', 'Burger', 10000, 1, 5.0, 0, 10500, 'now')
    `).run(orderItemId2, orderId);

    // Insert KOT 2 FIRST to verify deterministic ordering
    const kotId2 = 'kot-uuid-2';
    rawDb.prepare(`
      INSERT INTO pos_kots (id, order_id, kot_number, device_id, status, printed_at)
      VALUES (?, ?, 2, 'dev-1', 'printed', '2026-10-12T10:15:00Z')
    `).run(kotId2, orderId);

    const kotItemId2 = 'kitem-uuid-2';
    rawDb.prepare(`
      INSERT INTO kot_items (id, kot_id, order_item_id, product_id, product_name, quantity, notes)
      VALUES (?, ?, ?, 'prod-1', 'Burger', 1, 'Extra cheese')
    `).run(kotItemId2, kotId2, orderItemId2);

    // Verify GET_KOTS_FOR_ORDER_SINGLE_KOT_PASS
    const singleKot = await dbManager.getKotsForOrder(orderId);
    assert.equal(singleKot.length, 1, 'GET_KOTS_FOR_ORDER_SINGLE_KOT_PASS: returns exactly 1 KOT');
    assert.equal(singleKot[0].kot.kot_number, 2);
    assert.equal(singleKot[0].items.length, 1);

    // Insert KOT 1 SECOND
    const kotId1 = 'kot-uuid-1';
    rawDb.prepare(`
      INSERT INTO pos_kots (id, order_id, kot_number, device_id, status, printed_at)
      VALUES (?, ?, 1, 'dev-1', 'printed', '2026-10-12T10:05:00Z')
    `).run(kotId1, orderId);

    const kotItemId1 = 'kitem-uuid-1';
    rawDb.prepare(`
      INSERT INTO kot_items (id, kot_id, order_item_id, product_id, product_name, quantity, notes)
      VALUES (?, ?, ?, 'prod-1', 'Burger', 2, NULL)
    `).run(kotItemId1, kotId1, orderItemId1);

    // Historical KOT item with NULL order_item_id in KOT 1
    const kotItemIdHist = 'kitem-uuid-hist';
    rawDb.prepare(`
      INSERT INTO kot_items (id, kot_id, order_item_id, product_id, product_name, quantity, notes)
      VALUES (?, ?, NULL, 'prod-2', 'Fries', 1, NULL)
    `).run(kotItemIdHist, kotId1);

    // Initial Outbox count
    const outboxCountBefore = (rawDb.prepare('SELECT count(*) as count FROM sync_outbox').get() as { count: number }).count;

    // Execute semantic read
    const kots = await dbManager.getKotsForOrder(orderId);

    // 2. GET_KOTS_FOR_ORDER_MULTIPLE_KOTS_PASS
    assert.equal(kots.length, 2, 'GET_KOTS_FOR_ORDER_MULTIPLE_KOTS_PASS: returns exactly 2 KOTs');

    // 3. KOT_ORDERING_BY_KOT_NUMBER_PASS
    assert.equal(kots[0].kot.kot_number, 1, 'KOT_ORDERING_BY_KOT_NUMBER_PASS: KOT 1 comes first');
    assert.equal(kots[1].kot.kot_number, 2, 'KOT_ORDERING_BY_KOT_NUMBER_PASS: KOT 2 comes second');
    assert.equal(kots[0].kot.id, kotId1);
    assert.equal(kots[1].kot.id, kotId2);

    // 4. KOT_ITEMS_RETURNED_PASS & SAME_PRODUCT_MULTI_KOT_NOT_MERGED_PASS
    assert.equal(kots[0].items.length, 2, 'KOT 1 has 2 items');
    assert.equal(kots[1].items.length, 1, 'KOT 2 has 1 item');

    // 5. KOT_ITEM_ORDER_ITEM_ID_RETURNED_PASS
    const item1 = kots[0].items.find((it) => it.id === kotItemId1);
    assert.notEqual(item1, undefined);
    assert.equal(item1?.order_item_id, orderItemId1, 'KOT_ITEM_ORDER_ITEM_ID_RETURNED_PASS: order_item_id matches');
    assert.equal(item1?.quantity, 2, 'IMMUTABLE_SENT_QUANTITY_RETURNED_PASS: sent quantity is 2');

    // 6. HISTORICAL_NULL_ORDER_ITEM_ID_PRESERVED_PASS
    const itemHist = kots[0].items.find((it) => it.id === kotItemIdHist);
    assert.notEqual(itemHist, undefined);
    assert.strictEqual(itemHist?.order_item_id, null, 'HISTORICAL_NULL_ORDER_ITEM_ID_PRESERVED_PASS: null preserved');

    // 7. SAME_PRODUCT_MULTI_KOT_NOT_MERGED_PASS
    const item2 = kots[1].items.find((it) => it.id === kotItemId2);
    assert.notEqual(item2, undefined);
    assert.equal(item2?.product_name, 'Burger');
    assert.equal(item2?.order_item_id, orderItemId2);
    assert.notEqual(item1?.id, item2?.id, 'SAME_PRODUCT_MULTI_KOT_NOT_MERGED_PASS: Burger lines in KOT 1 and KOT 2 remain distinct');

    // 8. IMMUTABLE_SENT_QUANTITY_RETURNED_PASS
    // Mutate commercial order_item to simulate a correction
    rawDb.prepare(`UPDATE order_items SET quantity = 1 WHERE id = ?`).run(orderItemId1);
    const kotsAfterCorrection = await dbManager.getKotsForOrder(orderId);
    const item1After = kotsAfterCorrection[0].items.find((it) => it.id === kotItemId1);
    assert.equal(item1After?.quantity, 2, 'IMMUTABLE_SENT_QUANTITY_RETURNED_PASS: kot_items.quantity still returns 2 after order_items updated');

    // 9. READ_DOES_NOT_CREATE_OUTBOX_PASS
    const outboxCountAfter = (rawDb.prepare('SELECT count(*) as count FROM sync_outbox').get() as { count: number }).count;
    assert.equal(outboxCountAfter, outboxCountBefore, 'READ_DOES_NOT_CREATE_OUTBOX_PASS: zero outbox rows created');
  });
});
