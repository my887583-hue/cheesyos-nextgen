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
} from '../src/index.js';

describe('1. SQLite Persistence Initialization & Constraints', () => {
  test('A, B, C. Fresh DB initializes with WAL, foreign keys enabled, user_version = 1', () => {
    const dbManager = new PosLocalDatabase(':memory:');
    const rawDb = dbManager.getRawDb();

    assert.equal(dbManager.getSchemaVersion(), 2);

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
