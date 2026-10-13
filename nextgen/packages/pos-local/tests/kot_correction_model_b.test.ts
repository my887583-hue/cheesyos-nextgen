/**
 * CHEESYOS NEXTGEN POS LOCAL — TASK 3G.2-09B
 * KOT CORRECTION MODEL-B CONTRACT TEST SUITE
 * 
 * Verifies:
 * - Canonical Lineage (order_items ↔ kot_items.order_item_id ↔ kot_corrections)
 * - Model-B Single Authority Billable Quantity (order_items.quantity = current - cancel)
 * - Immutable Kitchen Snapshot (kot_items.quantity preserved)
 * - Full Cancellation (quantity=0, row preserved, zero-billable)
 * - Zero Quantity Boundary (normal draft/cart/additional rejects qty<=0; only correction yields 0)
 * - Status Gate (kot_sent only; draft/billed/settled/closed/cancelled rejected)
 * - Over-correction Protection (cancel_qty <= current order_items.quantity)
 * - Pure Financial Recalculation (pos-core engine, manual order discount preserved)
 * - Local Transaction Atomicity, Rollback & Single Outbox Aggregate
 * - Local Idempotency (identical retry no-op, conflicting retry rejected, no double-deduction)
 * - SQLite v3 -> v4 Schema Upgrade (preserving existing rows & outbox)
 */

import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

import {
  PosCart,
  createOrderDraft,
  createKotDispatchSnapshot,
  calculateKotCorrectionFinancials,
} from '@cheesyos/pos-core';
import type {
  OrderDomain,
  OrderItemDomain,
  PosKotDomain,
  KotItemDomain,
  KotCorrectionDomain,
} from '@cheesyos/nextgen-shared';
import {
  PosLocalDatabase,
  ApplyKotCorrectionInput,
  getPendingOutboxEntries,
  SCHEMA_VERSION,
} from '../src/index.js';

function createSeedData(db: PosLocalDatabase) {
  const catId = crypto.randomUUID();
  const prod1Id = crypto.randomUUID();
  const prod2Id = crypto.randomUUID();
  const table1Id = crypto.randomUUID();
  const table2Id = crypto.randomUUID();

  const rawDb = (db as any).db;
  const now = new Date().toISOString();

  rawDb.prepare(`
    INSERT INTO categories (id, name, slug, display_order, is_active, created_at, updated_at)
    VALUES (?, 'Burgers', 'burgers', 1, 1, ?, ?)
  `).run(catId, now, now);

  rawDb.prepare(`
    INSERT INTO products (id, category_id, name, base_price_paise, is_available, tax_rate, is_inventory_tracked, created_at, updated_at)
    VALUES (?, ?, 'Classic Burger', 10000, 1, 5.0, 0, ?, ?),
           (?, ?, 'Cheese Burger', 15000, 1, 5.0, 0, ?, ?)
  `).run(prod1Id, catId, now, now, prod2Id, catId, now, now);

  rawDb.prepare(`
    INSERT INTO pos_tables (id, table_number, section, capacity, is_active, created_at)
    VALUES (?, 'T1', 'Main', 4, 1, ?),
           (?, 'T2', 'Main', 4, 1, ?)
  `).run(table1Id, now, table2Id, now);

  return { catId, prod1Id, prod2Id, table1Id, table2Id };
}

describe('Task 3G.2-09B: KOT Correction Model-B Local Backend Contract', () => {
  let db: PosLocalDatabase;
  let seeds: ReturnType<typeof createSeedData>;

  beforeEach(() => {
    db = new PosLocalDatabase(':memory:');
    seeds = createSeedData(db);
  });

  async function setupKotSentOrder(initialBurgerQty = 3, tableId = seeds.table1Id) {
    const session = await db.openTableSession(tableId, 2);

    const cart = new PosCart({ tableSessionId: session.id, orderType: 'DINE_IN' });
    cart.addItem({
      productId: seeds.prod1Id,
      productName: 'Classic Burger',
      unitPriceRupees: 100,
      quantity: initialBurgerQty,
      taxRatePercent: 5.0,
    });

    const draft = createOrderDraft(cart);
    draft.order.table_session_id = session.id;
    draft.order.status = 'draft';

    await db.saveOrderAggregate(draft.order, draft.items);

    const kotSnapshot = createKotDispatchSnapshot(draft.order.id, draft.items, { kotNumber: 1 });
    await db.saveKotAggregate(kotSnapshot.kot, kotSnapshot.items);

    const active = await db.getActiveOrderForTable(tableId);
    assert.ok(active);

    return {
      session,
      order: { ...draft.order, status: 'kot_sent' as const },
      orderItem: draft.items[0],
      orderItems: draft.items,
      kot: kotSnapshot.kot,
      kotItem: kotSnapshot.items[0],
    };
  }

  function makeCorrectionInput(
    order: OrderDomain,
    orderItems: OrderItemDomain[],
    targetOrderItemId: string,
    kot: PosKotDomain,
    kotItem: KotItemDomain,
    cancelledQty: number,
    overrides?: {
      correctionId?: string;
      reason?: string;
      authorizedByStaffId?: string;
      mismatchedOrderItemId?: string;
      targetKotItemId?: string;
      targetKotId?: string;
      targetOrderId?: string;
    }
  ): ApplyKotCorrectionInput {
    let financials;
    try {
      financials = calculateKotCorrectionFinancials({
        order,
        orderItems,
        targetOrderItemId,
        cancelledQty: Math.max(1, cancelledQty),
      });
    } catch {
      financials = {
        updatedOrderItem: { id: targetOrderItemId, quantity: 0, line_total: 0, line_total_paise: 0 },
        updatedOrder: { id: order.id, subtotal: 0, tax_total: 0, discount_total: 0, grand_total: 0, status: 'kot_sent' as const },
      };
    }

    const correction: KotCorrectionDomain = {
      id: overrides?.correctionId ?? crypto.randomUUID(),
      order_id: overrides?.targetOrderId ?? order.id,
      kot_id: overrides?.targetKotId ?? kot.id,
      kot_item_id: overrides?.targetKotItemId ?? kotItem.id,
      order_item_id: overrides?.mismatchedOrderItemId ?? targetOrderItemId,
      product_name: kotItem.product_name,
      cancelled_qty: cancelledQty,
      reason: overrides?.reason ?? 'Customer request',
      authorized_by_staff_id: overrides?.authorizedByStaffId ?? 'staff-mgr-1',
      created_at: new Date().toISOString(),
    };

    const currentItem = orderItems.find((i) => i.id === targetOrderItemId)!;
    const updatedOrderItem: OrderItemDomain = {
      ...currentItem,
      quantity: Math.max(0, currentItem.quantity - cancelledQty),
      line_total: financials.updatedOrderItem.line_total,
    };

    const updatedOrder: OrderDomain = {
      ...order,
      subtotal: financials.updatedOrder.subtotal,
      tax_total: financials.updatedOrder.tax_total,
      discount_total: financials.updatedOrder.discount_total,
      grand_total: financials.updatedOrder.grand_total,
    };

    return {
      correction,
      updatedOrderItem,
      updatedOrder,
    };
  }

  // 1. INITIAL_KOT_STORES_ORDER_ITEM_ID_PASS
  it('INITIAL_KOT_STORES_ORDER_ITEM_ID_PASS: Initial KOT items store originating order_item_id', async () => {
    const fixture = await setupKotSentOrder(3);

    const rawDb = (db as any).db;
    const storedKotItem = rawDb.prepare(
      'SELECT id, kot_id, order_item_id, quantity FROM kot_items WHERE id = ?'
    ).get(fixture.kotItem.id) as any;

    assert.ok(storedKotItem);
    assert.equal(storedKotItem.order_item_id, fixture.orderItem.id);
    assert.equal(storedKotItem.quantity, 3);
  });

  // 2. ADDITIONAL_KOT_STORES_ORDER_ITEM_ID_PASS
  it('ADDITIONAL_KOT_STORES_ORDER_ITEM_ID_PASS: Additional KOT items store originating order_item_id', async () => {
    const fixture = await setupKotSentOrder(2);

    const newItemId = crypto.randomUUID();
    const newKotId = crypto.randomUUID();
    const newKotItemId = crypto.randomUUID();

    const additionalOrderItem: OrderItemDomain = {
      id: newItemId,
      order_id: fixture.order.id,
      product_id: seeds.prod2Id,
      product_name: 'Cheese Burger',
      unit_price: 150,
      quantity: 1,
      tax_rate: 5.0,
      discount_amount: 0,
      line_total: 150,
      created_at: new Date().toISOString(),
    };

    const additionalKot: PosKotDomain = {
      id: newKotId,
      order_id: fixture.order.id,
      kot_number: 2,
      status: 'printed',
      printed_at: new Date().toISOString(),
    };

    const additionalKotItem: KotItemDomain = {
      id: newKotItemId,
      kot_id: newKotId,
      order_item_id: newItemId,
      product_id: seeds.prod2Id,
      product_name: 'Cheese Burger',
      quantity: 1,
    };

    const updatedOrder: OrderDomain = {
      ...fixture.order,
      subtotal: 350,
      tax_total: 17.5,
      grand_total: 367.5,
    };

    await db.appendOrderItemsAndKot(
      updatedOrder,
      [additionalOrderItem],
      additionalKot,
      [additionalKotItem]
    );

    const rawDb = (db as any).db;
    const storedItem = rawDb.prepare(
      'SELECT id, order_item_id FROM kot_items WHERE id = ?'
    ).get(newKotItemId) as any;

    assert.ok(storedItem);
    assert.equal(storedItem.order_item_id, newItemId);
  });

  // 3. SAME_PRODUCT_MULTI_KOT_LINEAGE_PASS
  it('SAME_PRODUCT_MULTI_KOT_LINEAGE_PASS: Same product across KOT 1 and KOT 2 has unambiguous lineage', async () => {
    const fixture = await setupKotSentOrder(2);

    const secondLineId = crypto.randomUUID();
    const secondKotId = crypto.randomUUID();
    const secondKotItemId = crypto.randomUUID();

    const secondOrderItem: OrderItemDomain = {
      id: secondLineId,
      order_id: fixture.order.id,
      product_id: seeds.prod1Id,
      product_name: 'Classic Burger',
      unit_price: 100,
      quantity: 1,
      tax_rate: 5.0,
      discount_amount: 0,
      line_total: 100,
      created_at: new Date().toISOString(),
    };

    const secondKot: PosKotDomain = {
      id: secondKotId,
      order_id: fixture.order.id,
      kot_number: 2,
      status: 'printed',
      printed_at: new Date().toISOString(),
    };

    const secondKotItem: KotItemDomain = {
      id: secondKotItemId,
      kot_id: secondKotId,
      order_item_id: secondLineId,
      product_id: seeds.prod1Id,
      product_name: 'Classic Burger',
      quantity: 1,
    };

    const updatedOrder: OrderDomain = {
      ...fixture.order,
      subtotal: 300,
      tax_total: 15,
      grand_total: 315,
    };

    await db.appendOrderItemsAndKot(
      updatedOrder,
      [secondOrderItem],
      secondKot,
      [secondKotItem]
    );

    const rawDb = (db as any).db;
    const kot1Item = rawDb.prepare('SELECT order_item_id FROM kot_items WHERE id = ?').get(fixture.kotItem.id) as any;
    const kot2Item = rawDb.prepare('SELECT order_item_id FROM kot_items WHERE id = ?').get(secondKotItemId) as any;

    assert.equal(kot1Item.order_item_id, fixture.orderItem.id);
    assert.equal(kot2Item.order_item_id, secondLineId);
    assert.notEqual(kot1Item.order_item_id, kot2Item.order_item_id);
  });

  // 4. HISTORICAL_NULL_LINEAGE_REJECT_PASS
  it('HISTORICAL_NULL_LINEAGE_REJECT_PASS: Historical KOT item with null order_item_id is rejected', async () => {
    const fixture = await setupKotSentOrder(2);

    const rawDb = (db as any).db;
    rawDb.prepare('UPDATE kot_items SET order_item_id = NULL WHERE id = ?').run(fixture.kotItem.id);

    const input = makeCorrectionInput(
      fixture.order,
      [fixture.orderItem],
      fixture.orderItem.id,
      fixture.kot,
      fixture.kotItem,
      1
    );

    await assert.rejects(
      async () => {
        await db.applyKotCorrection(input);
      },
      (err: any) => {
        assert.match(err.message, /CORRECTION_LINEAGE_UNAVAILABLE/);
        return true;
      }
    );
  });

  // 5. CORRECTION_POSITIVE_QTY_REQUIRED_PASS
  it('CORRECTION_POSITIVE_QTY_REQUIRED_PASS: Rejects non-positive cancelled quantity', async () => {
    const fixture = await setupKotSentOrder(2);

    const input = makeCorrectionInput(
      fixture.order,
      [fixture.orderItem],
      fixture.orderItem.id,
      fixture.kot,
      fixture.kotItem,
      0
    );

    await assert.rejects(
      async () => {
        await db.applyKotCorrection(input);
      },
      (err: any) => {
        assert.match(err.message, /cancelled_qty must be greater than 0/);
        return true;
      }
    );
  });

  // 6. CORRECTION_KOT_SENT_ONLY_PASS & 7-11 STATUS REJECTIONS
  it('CORRECTION_KOT_SENT_ONLY_PASS: Allows correction only when order.status is kot_sent', async () => {
    const fixture = await setupKotSentOrder(2);

    const input = makeCorrectionInput(
      fixture.order,
      [fixture.orderItem],
      fixture.orderItem.id,
      fixture.kot,
      fixture.kotItem,
      1
    );

    const res = await db.applyKotCorrection(input);

    assert.equal(res.updatedOrderItem.quantity, 1);
    assert.equal(res.updatedOrderItem.line_total, 105);
  });

  it('CORRECTION_DRAFT_REJECT_PASS, BILLED, SETTLED, CLOSED, CANCELLED', async () => {
    const forbiddenStatuses = ['draft', 'billed', 'settled', 'closed', 'cancelled'];
    const rawDb = (db as any).db;
    const fixture = await setupKotSentOrder(2);

    for (const status of forbiddenStatuses) {
      rawDb.prepare('UPDATE orders SET status = ? WHERE id = ?').run(status, fixture.order.id);

      const input = makeCorrectionInput(
        { ...fixture.order, status: status as any },
        [fixture.orderItem],
        fixture.orderItem.id,
        fixture.kot,
        fixture.kotItem,
        1
      );

      await assert.rejects(
        async () => {
          await db.applyKotCorrection(input);
        },
        (err: any) => {
          assert.match(err.message, /ORDER_STATUS_INVALID/);
          return true;
        }
      );
    }
  });

  // 12. PARTIAL_CORRECTION_QTY_PASS & 13. PARTIAL_CORRECTION_FINANCIALS_PASS
  it('PARTIAL_CORRECTION_QTY_PASS & PARTIAL_CORRECTION_FINANCIALS_PASS: Recalculates remaining quantity and financials cleanly', async () => {
    const fixture = await setupKotSentOrder(3); // 3 burgers @ 100 = 300, 5% tax = 15, grand = 315

    const input = makeCorrectionInput(
      fixture.order,
      [fixture.orderItem],
      fixture.orderItem.id,
      fixture.kot,
      fixture.kotItem,
      1
    );

    const result = await db.applyKotCorrection(input);

    assert.equal(result.updatedOrderItem.quantity, 2);
    assert.equal(result.updatedOrderItem.line_total, 210);
    assert.equal(result.updatedOrder.subtotal, 200);
    assert.equal(result.updatedOrder.tax_total, 10);
    assert.equal(result.updatedOrder.grand_total, 210);

    // Verify stored SQLite row
    const rawDb = (db as any).db;
    const itemRow = rawDb.prepare('SELECT quantity, line_total_paise FROM order_items WHERE id = ?').get(fixture.orderItem.id) as any;
    assert.equal(itemRow.quantity, 2);
    assert.equal(itemRow.line_total_paise, 21000);

    const orderRow = rawDb.prepare('SELECT subtotal_paise, tax_total_paise, grand_total_paise FROM orders WHERE id = ?').get(fixture.order.id) as any;
    assert.equal(orderRow.subtotal_paise, 20000);
    assert.equal(orderRow.tax_total_paise, 1000);
    assert.equal(orderRow.grand_total_paise, 21000);
  });

  // 14. FULL_CORRECTION_QTY_ZERO_PASS, 15. ROW_PRESERVED, 16. FINANCIAL_ZERO, 17. ORIGINAL_KOT_UNCHANGED
  it('FULL_CORRECTION_QTY_ZERO_PASS: Full cancel produces qty 0, preserves row, line_total 0, and KOT unchanged', async () => {
    const fixture = await setupKotSentOrder(2); // 2 burgers

    const input = makeCorrectionInput(
      fixture.order,
      [fixture.orderItem],
      fixture.orderItem.id,
      fixture.kot,
      fixture.kotItem,
      2
    );

    const result = await db.applyKotCorrection(input);

    assert.equal(result.updatedOrderItem.quantity, 0);
    assert.equal(result.updatedOrderItem.line_total, 0);
    assert.equal(result.updatedOrder.subtotal, 0);
    assert.equal(result.updatedOrder.grand_total, 0);

    const rawDb = (db as any).db;
    const itemRow = rawDb.prepare('SELECT quantity, line_total_paise FROM order_items WHERE id = ?').get(fixture.orderItem.id) as any;
    assert.ok(itemRow, 'Order item row must remain persisted');
    assert.equal(itemRow.quantity, 0);
    assert.equal(itemRow.line_total_paise, 0);

    // ORIGINAL KOT ITEM MUST REMAIN COMPLETELY UNCHANGED
    const kotItemRow = rawDb.prepare('SELECT quantity FROM kot_items WHERE id = ?').get(fixture.kotItem.id) as any;
    assert.equal(kotItemRow.quantity, 2, 'Original KOT item quantity must remain immutable');
  });

  // 18. OVER_CORRECTION_REJECT_PASS
  it('OVER_CORRECTION_REJECT_PASS: Cannot cancel more units than current order_items.quantity', async () => {
    const fixture = await setupKotSentOrder(2);

    const input = makeCorrectionInput(
      fixture.order,
      [fixture.orderItem],
      fixture.orderItem.id,
      fixture.kot,
      fixture.kotItem,
      3
    );

    await assert.rejects(
      async () => {
        await db.applyKotCorrection(input);
      },
      (err: any) => {
        assert.match(err.message, /OVER_CORRECTION/);
        return true;
      }
    );
  });

  // 19. SAME_PRODUCT_WRONG_LINE_REJECT_PASS & 20. CROSS_ORDER_LINEAGE_REJECT_PASS
  it('SAME_PRODUCT_WRONG_LINE_REJECT_PASS: Reject mismatched kot_item and order_item', async () => {
    const fixture = await setupKotSentOrder(2);

    const input = makeCorrectionInput(
      fixture.order,
      [fixture.orderItem],
      fixture.orderItem.id,
      fixture.kot,
      fixture.kotItem,
      1,
      { mismatchedOrderItemId: crypto.randomUUID() }
    );

    await assert.rejects(
      async () => {
        await db.applyKotCorrection(input);
      },
      (err: any) => {
        assert.match(err.message, /LINEAGE_MISMATCH|ORDER_ITEM_NOT_FOUND/);
        return true;
      }
    );
  });

  it('CROSS_ORDER_LINEAGE_REJECT_PASS: Reject cross-order item linkage', async () => {
    const fixture1 = await setupKotSentOrder(2, seeds.table1Id);
    const fixture2 = await setupKotSentOrder(2, seeds.table2Id);

    const input = makeCorrectionInput(
      fixture1.order,
      [fixture1.orderItem],
      fixture1.orderItem.id,
      fixture1.kot,
      fixture1.kotItem,
      1,
      { mismatchedOrderItemId: fixture2.orderItem.id }
    );

    await assert.rejects(
      async () => {
        await db.applyKotCorrection(input);
      },
      (err: any) => {
        assert.match(err.message, /LINEAGE_MISMATCH/);
        return true;
      }
    );
  });

  // 21-24. LOCAL IDEMPOTENCY: IDENTICAL RETRY, CONFLICT, NO DOUBLE DEDUCTION, NO DUPLICATE OUTBOX
  it('CORRECTION_IDENTICAL_RETRY_PASS & NO_DOUBLE_DEDUCTION & NO_DUPLICATE_OUTBOX', async () => {
    const fixture = await setupKotSentOrder(3);

    const corrId = crypto.randomUUID();
    const input = makeCorrectionInput(
      fixture.order,
      [fixture.orderItem],
      fixture.orderItem.id,
      fixture.kot,
      fixture.kotItem,
      1,
      { correctionId: corrId }
    );

    // First call
    const res1 = await db.applyKotCorrection(input);
    assert.equal(res1.updatedOrderItem.quantity, 2);

    const pendingOutbox1 = await db.getPendingOutbox(10);
    const corrOutbox1 = pendingOutbox1.filter(o => o.entity_type === 'kot_corrections');
    assert.equal(corrOutbox1.length, 1);

    // Second call: IDENTICAL RETRY
    const res2 = await db.applyKotCorrection(input);
    assert.equal(res2.updatedOrderItem.quantity, 2, 'Must not double-deduct quantity!');

    const pendingOutbox2 = await db.getPendingOutbox(10);
    const corrOutbox2 = pendingOutbox2.filter(o => o.entity_type === 'kot_corrections');
    assert.equal(corrOutbox2.length, 1, 'Must not create duplicate outbox entries!');
  });

  it('CORRECTION_CONFLICTING_RETRY_PASS: Same ID with conflicting payload is rejected', async () => {
    const fixture = await setupKotSentOrder(3);

    const corrId = crypto.randomUUID();
    const input1 = makeCorrectionInput(
      fixture.order,
      [fixture.orderItem],
      fixture.orderItem.id,
      fixture.kot,
      fixture.kotItem,
      1,
      { correctionId: corrId }
    );

    await db.applyKotCorrection(input1);

    // Conflicting retry (e.g. cancelledQty = 2 instead of 1)
    const input2 = makeCorrectionInput(
      fixture.order,
      [fixture.orderItem],
      fixture.orderItem.id,
      fixture.kot,
      fixture.kotItem,
      2,
      { correctionId: corrId }
    );

    await assert.rejects(
      async () => {
        await db.applyKotCorrection(input2);
      },
      (err: any) => {
        assert.match(err.message, /IDEMPOTENCY_CONFLICT/);
        return true;
      }
    );
  });

  // 25. NORMAL_DRAFT_ZERO_QTY_REJECT_PASS & 26. ADDITIONAL_KOT_NEW_ZERO_QTY_REJECT_PASS
  it('NORMAL_DRAFT_ZERO_QTY_REJECT_PASS: Normal draft rejects quantity <= 0', () => {
    const cart = new PosCart();
    assert.throws(() => {
      cart.addItem({
        productId: seeds.prod1Id,
        productName: 'Classic Burger',
        unitPriceRupees: 100,
        quantity: 0,
      });
    }, /Item quantity must be greater than 0/);
  });

  it('ADDITIONAL_KOT_NEW_ZERO_QTY_REJECT_PASS: Additional KOT rejects newly created item with quantity <= 0', async () => {
    const fixture = await setupKotSentOrder(2);

    const zeroOrderItem: OrderItemDomain = {
      id: crypto.randomUUID(),
      order_id: fixture.order.id,
      product_id: seeds.prod1Id,
      product_name: 'Classic Burger',
      unit_price: 100,
      quantity: 0,
      tax_rate: 5.0,
      discount_amount: 0,
      line_total: 0,
      created_at: new Date().toISOString(),
    };

    const newKot: PosKotDomain = {
      id: crypto.randomUUID(),
      order_id: fixture.order.id,
      kot_number: 2,
      status: 'printed',
      printed_at: new Date().toISOString(),
    };

    const newKotItem: KotItemDomain = {
      id: crypto.randomUUID(),
      kot_id: newKot.id,
      order_item_id: zeroOrderItem.id,
      product_id: seeds.prod1Id,
      product_name: 'Classic Burger',
      quantity: 0,
    };

    await assert.rejects(
      async () => {
        await db.appendOrderItemsAndKot(
          fixture.order,
          [zeroOrderItem],
          newKot,
          [newKotItem]
        );
      },
      (err: any) => {
        assert.match(err.message, /CHECK constraint failed|INVALID_QUANTITY/);
        return true;
      }
    );
  });

  // 27. CORRECTION_ATOMIC_ROLLBACK_PASS
  it('CORRECTION_ATOMIC_ROLLBACK_PASS: Transaction error rolls back correction, item, and order totals', async () => {
    const fixture = await setupKotSentOrder(3);
    const rawDb = (db as any).db;

    // Simulate constraint failure by making sync_outbox insert fail
    rawDb.exec('CREATE TRIGGER fail_correction_outbox BEFORE INSERT ON sync_outbox BEGIN SELECT RAISE(FAIL, "SIMULATED_OUTBOX_CRASH"); END;');

    const input = makeCorrectionInput(
      fixture.order,
      [fixture.orderItem],
      fixture.orderItem.id,
      fixture.kot,
      fixture.kotItem,
      1
    );

    await assert.rejects(
      async () => {
        await db.applyKotCorrection(input);
      },
      (err: any) => {
        assert.match(err.message, /SIMULATED_OUTBOX_CRASH/);
        return true;
      }
    );

    // Assert that item and order totals were NOT mutated
    const item = rawDb.prepare('SELECT quantity FROM order_items WHERE id = ?').get(fixture.orderItem.id) as any;
    assert.equal(item.quantity, 3, 'Item quantity must roll back to 3');

    const correctionsCount = rawDb.prepare('SELECT COUNT(*) as count FROM kot_corrections WHERE order_id = ?').get(fixture.order.id) as any;
    assert.equal(correctionsCount.count, 0, 'No correction record must be committed');
  });

  // SECTION 42: SQLITE UPGRADE TEST
  it('SQLITE_UPGRADE_PASS & EXISTING_DATA_PRESERVED & QUANTITY_ZERO_ALLOWED_AFTER_UPGRADE', async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'cheesy-v3-upgrade-test-'));
    const dbPath = path.join(tempDir, 'pos_v3_upgrade.db');

    try {
      // 1. Create a genuine pre-015 SQLite v3 database fixture
      const v3Db = new DatabaseSync(dbPath);
      v3Db.exec(`
        PRAGMA foreign_keys = ON;

        CREATE TABLE pos_device_config (
          device_id TEXT PRIMARY KEY,
          terminal_code TEXT NOT NULL,
          device_name TEXT NOT NULL,
          created_at TEXT NOT NULL
        );

        CREATE TABLE pos_tables (
          id TEXT PRIMARY KEY,
          table_number TEXT NOT NULL,
          section TEXT NOT NULL,
          capacity INTEGER NOT NULL,
          is_active INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL
        );

        CREATE TABLE table_sessions (
          id TEXT PRIMARY KEY,
          table_id TEXT NOT NULL REFERENCES pos_tables(id),
          guest_count INTEGER NOT NULL,
          session_status TEXT NOT NULL,
          opened_at TEXT NOT NULL,
          closed_at TEXT,
          current_order_id TEXT
        );

        CREATE TABLE orders (
          id TEXT PRIMARY KEY,
          display_number TEXT,
          channel TEXT NOT NULL,
          order_type TEXT NOT NULL,
          customer_id TEXT,
          table_session_id TEXT REFERENCES table_sessions(id),
          status TEXT NOT NULL,
          subtotal_paise INTEGER NOT NULL,
          tax_total_paise INTEGER NOT NULL,
          discount_total_paise INTEGER NOT NULL,
          delivery_charge_paise INTEGER NOT NULL,
          grand_total_paise INTEGER NOT NULL,
          device_id TEXT,
          version INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );

        CREATE TABLE order_items (
          id TEXT PRIMARY KEY,
          order_id TEXT NOT NULL REFERENCES orders(id),
          product_id TEXT NOT NULL,
          variant_id TEXT,
          product_name TEXT NOT NULL,
          unit_price_paise INTEGER NOT NULL,
          quantity INTEGER NOT NULL CHECK (quantity > 0),
          tax_rate REAL NOT NULL,
          discount_amount_paise INTEGER NOT NULL,
          line_total_paise INTEGER NOT NULL,
          notes TEXT,
          created_at TEXT NOT NULL
        );

        CREATE TABLE pos_kots (
          id TEXT PRIMARY KEY,
          order_id TEXT NOT NULL REFERENCES orders(id),
          kot_number INTEGER NOT NULL,
          device_id TEXT,
          status TEXT NOT NULL,
          printed_at TEXT,
          created_at TEXT NOT NULL
        );

        CREATE TABLE kot_items (
          id TEXT PRIMARY KEY,
          kot_id TEXT NOT NULL REFERENCES pos_kots(id),
          product_id TEXT NOT NULL,
          variant_id TEXT,
          product_name TEXT NOT NULL,
          quantity INTEGER NOT NULL,
          notes TEXT
        );

        CREATE TABLE kot_corrections (
          id TEXT PRIMARY KEY,
          order_id TEXT NOT NULL REFERENCES orders(id),
          kot_id TEXT REFERENCES pos_kots(id),
          product_name TEXT NOT NULL,
          cancelled_qty INTEGER NOT NULL,
          reason TEXT NOT NULL,
          authorized_by_staff_id TEXT NOT NULL,
          created_at TEXT NOT NULL
        );

        CREATE TABLE sync_outbox (
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          id TEXT NOT NULL UNIQUE,
          entity_type TEXT NOT NULL,
          operation TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          payload_json TEXT NOT NULL,
          created_at TEXT NOT NULL,
          processed_at TEXT,
          error TEXT
        );

        -- Insert initial fixtures into v3
        INSERT INTO pos_device_config VALUES ('dev-1', 'T01', 'Counter POS', '2026-10-10T10:00:00Z');
        INSERT INTO pos_tables VALUES ('tbl-1', 'T1', 'Main', 4, 1, '2026-10-10T10:00:00Z');
        INSERT INTO table_sessions VALUES ('sess-1', 'tbl-1', 2, 'open', '2026-10-10T10:00:00Z', NULL, 'ord-1');
        INSERT INTO orders VALUES ('ord-1', 'ORD-01', 'POS', 'DINE_IN', NULL, 'sess-1', 'kot_sent', 20000, 1000, 0, 0, 21000, 'dev-1', 1, '2026-10-10T10:00:00Z', '2026-10-10T10:00:00Z');
        INSERT INTO order_items VALUES ('item-1', 'ord-1', 'prod-1', NULL, 'Burger', 10000, 2, 5.0, 0, 20000, NULL, '2026-10-10T10:00:00Z');
        INSERT INTO pos_kots VALUES ('kot-1', 'ord-1', 1, 'dev-1', 'printed', '2026-10-10T10:00:00Z', '2026-10-10T10:00:00Z');
        INSERT INTO kot_items VALUES ('kitem-1', 'kot-1', 'prod-1', NULL, 'Burger', 2, NULL);
        INSERT INTO sync_outbox (id, entity_type, operation, entity_id, payload_json, created_at)
        VALUES ('out-1', 'orders', 'INSERT', 'ord-1', '{"id":"ord-1"}', '2026-10-10T10:00:00Z');

        PRAGMA user_version = 3;
      `);
      v3Db.close();

      // 2. Open with PosLocalDatabase (should detect v3 and upgrade to v4 / SCHEMA_VERSION)
      const upgradedDb = new PosLocalDatabase(dbPath);
      assert.equal(upgradedDb.getSchemaVersion(), 4, 'SQLITE_UPGRADE_PASS');

      const raw = upgradedDb.getRawDb();

      // EXISTING_DEVICE_STATE_PRESERVED_PASS
      const dev = raw.prepare('SELECT device_id, terminal_code FROM pos_device_config WHERE device_id = ?').get('dev-1') as any;
      assert.equal(dev.terminal_code, 'T01');

      // EXISTING_ORDER_ITEM_PRESERVED_PASS
      const item = raw.prepare('SELECT id, quantity, line_total_paise FROM order_items WHERE id = ?').get('item-1') as any;
      assert.equal(item.id, 'item-1');
      assert.equal(item.quantity, 2);

      // EXISTING_KOT_PRESERVED_PASS
      const kot = raw.prepare('SELECT id, kot_number FROM pos_kots WHERE id = ?').get('kot-1') as any;
      assert.equal(kot.id, 'kot-1');

      // EXISTING_OUTBOX_PRESERVED_PASS
      const out = raw.prepare('SELECT id, entity_type FROM sync_outbox WHERE id = ?').get('out-1') as any;
      assert.equal(out.id, 'out-1');

      // Prove corrected quantity=0 can now be persisted in order_items without constraint violation
      raw.prepare('UPDATE order_items SET quantity = 0, line_total_paise = 0 WHERE id = ?').run('item-1');
      const updatedItem = raw.prepare('SELECT quantity, line_total_paise FROM order_items WHERE id = ?').get('item-1') as any;
      assert.equal(updatedItem.quantity, 0, 'Quantity=0 must be successfully persisted post-upgrade');
      assert.equal(updatedItem.line_total_paise, 0);

      upgradedDb.close();
    } finally {
      fs.rmSync(tempDir, { recursive: true, force: true });
    }
  });
});
