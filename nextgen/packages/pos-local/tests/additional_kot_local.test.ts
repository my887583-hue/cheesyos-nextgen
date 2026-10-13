/**
 * CHEESYOS NEXTGEN POS LOCAL — ADDITIONAL KOT CONTRACT TEST SUITE (Task 3G.2-08A)
 * 
 * Verifies atomic post-KOT commercial append, monotonic KOT numbering,
 * cumulative totals, sent item immutability, outbox generation, and idempotent retries.
 */

import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { PosLocalDatabase } from '../src/database.js';
import { PosCart, createOrderDraft, createKotDispatchSnapshot } from '@cheesyos/pos-core';
import type { OrderDomain, OrderItemDomain, PosKotDomain, KotItemDomain } from '@cheesyos/nextgen-shared';

function createSeedData(db: PosLocalDatabase) {
  const catId = crypto.randomUUID();
  const prod1Id = crypto.randomUUID();
  const prod2Id = crypto.randomUUID();
  const tableId = crypto.randomUUID();

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
    VALUES (?, 'T1', 'Main', 4, 1, ?)
  `).run(tableId, now);

  return { catId, prod1Id, prod2Id, tableId };
}

function toOrderDomain(header: any, overrides: Partial<OrderDomain> = {}): OrderDomain {
  return {
    id: header.id,
    display_number: header.display_number,
    channel: header.channel,
    order_type: header.order_type,
    customer_id: header.customer_id,
    table_session_id: header.table_session_id,
    status: header.status,
    subtotal: header.subtotal ?? (header.subtotal_paise !== undefined ? header.subtotal_paise / 100 : 0),
    tax_total: header.tax_total ?? (header.tax_total_paise !== undefined ? header.tax_total_paise / 100 : 0),
    discount_total: header.discount_total ?? (header.discount_total_paise !== undefined ? header.discount_total_paise / 100 : 0),
    delivery_charge: header.delivery_charge ?? (header.delivery_charge_paise !== undefined ? header.delivery_charge_paise / 100 : 0),
    grand_total: header.grand_total ?? (header.grand_total_paise !== undefined ? header.grand_total_paise / 100 : 0),
    device_id: header.device_id,
    version: header.version,
    created_at: header.created_at,
    updated_at: header.updated_at,
    ...overrides,
  };
}

describe('Task 3G.2-08A: Atomic Additional KOT Contract (Local Persistence)', () => {
  let db: PosLocalDatabase;
  let seeds: ReturnType<typeof createSeedData>;

  beforeEach(() => {
    db = new PosLocalDatabase(':memory:');
    seeds = createSeedData(db);
  });

  async function setupKotSentOrder() {
    const session = await db.openTableSession(seeds.tableId, 2);

    // Initial cart with 2 Classic Burgers
    const cart1 = new PosCart({ tableSessionId: session.id, orderType: 'DINE_IN' });
    cart1.addItem({
      productId: seeds.prod1Id,
      productName: 'Classic Burger',
      unitPriceRupees: 100,
      quantity: 2,
      taxRatePercent: 5.0,
    });

    const draft1 = createOrderDraft(cart1);
    draft1.order.table_session_id = session.id;
    draft1.order.status = 'draft';

    const savedOrder = await db.saveOrderAggregate(draft1.order, draft1.items);

    const kot1Snapshot = createKotDispatchSnapshot(draft1.order.id, draft1.items, { kotNumber: 1 });
    await db.saveKotAggregate(kot1Snapshot.kot, kot1Snapshot.items);

    const active = await db.getActiveOrderForTable(seeds.tableId);
    assert.ok(active);
    assert.equal(active.order.status, 'kot_sent');
    assert.equal(active.items.length, 1);
    assert.equal(active.items[0].quantity, 2);

    return { session, activeOrder: active.order, initialItems: active.items, kot1Snapshot };
  }

  it('ADDITIONAL_KOT_KOT_SENT_ORDER_PASS — Successfully appends items and KOT #2 for kot_sent order', async () => {
    const { session, activeOrder } = await setupKotSentOrder();

    // Customer orders 1 Cheese Burger
    const newOrderItem: OrderItemDomain = {
      id: crypto.randomUUID(),
      order_id: activeOrder.id,
      product_id: seeds.prod2Id,
      variant_id: null,
      product_name: 'Cheese Burger',
      unit_price: 150,
      quantity: 1,
      tax_rate: 5.0,
      discount_amount: 0,
      line_total: 157.5,
      notes: null,
      created_at: new Date().toISOString(),
    };

    // Cumulative commercial order totals: (2 * 100 * 1.05) + (1 * 150 * 1.05) = 210 + 157.5 = 367.5
    const cumulativeOrder: OrderDomain = toOrderDomain(activeOrder, {
      subtotal: 350,
      tax_total: 17.5,
      grand_total: 367.5,
      updated_at: new Date().toISOString(),
    });

    const kot2Id = crypto.randomUUID();
    const kot2: PosKotDomain = {
      id: kot2Id,
      order_id: activeOrder.id,
      kot_number: 999, // Intentional placeholder; transaction must allocate 2
      device_id: null,
      status: 'printed',
      printed_at: new Date().toISOString(),
    };

    const kot2Items: KotItemDomain[] = [{
      id: crypto.randomUUID(),
      kot_id: kot2Id,
      product_id: seeds.prod2Id,
      variant_id: null,
      product_name: 'Cheese Burger',
      quantity: 1,
      notes: null,
    }];

    const result = await db.appendOrderItemsAndKot(cumulativeOrder, [newOrderItem], kot2, kot2Items);

    assert.equal(result.kot.kot_number, 2, 'Allocated KOT number must be 2');
    assert.equal(result.order.status, 'kot_sent', 'Order status must remain kot_sent');
    assert.equal(result.order.version, activeOrder.version, 'Order version must remain unchanged');
    assert.equal(result.order.grand_total, 367.5, 'Cumulative grand total must match');
    assert.equal(result.outboxEntries.length, 1, 'Exactly one outbox row emitted');
  });

  it('ADDITIONAL_KOT_DRAFT_REJECT_PASS — Rejects append on draft order', async () => {
    const session = await db.openTableSession(seeds.tableId, 2);
    const cart = new PosCart({ tableSessionId: session.id });
    cart.addItem({ productId: seeds.prod1Id, productName: 'Classic Burger', unitPriceRupees: 100, quantity: 1 });
    const draft = createOrderDraft(cart);
    draft.order.table_session_id = session.id;
    await db.saveOrderAggregate(draft.order, draft.items);

    const kot: PosKotDomain = {
      id: crypto.randomUUID(),
      order_id: draft.order.id,
      kot_number: 1,
      status: 'printed',
      printed_at: new Date().toISOString(),
    };

    await assert.rejects(
      async () => {
        await db.appendOrderItemsAndKot(draft.order, draft.items, kot, [{
          id: crypto.randomUUID(),
          kot_id: kot.id,
          product_id: seeds.prod1Id,
          variant_id: null,
          product_name: 'Classic Burger',
          quantity: 1,
          notes: null,
        }]);
      },
      /ORDER_STATUS_INVALID.*only 'kot_sent' orders/
    );
  });

  it('ADDITIONAL_KOT_BILLED_SETTLED_CLOSED_CANCELLED_REJECT_PASS — Rejects on non-kot_sent status', async () => {
    const { activeOrder, initialItems } = await setupKotSentOrder();
    const rawDb = (db as any).db;

    const invalidStatuses = ['billed', 'settled', 'closed', 'cancelled'];
    for (const st of invalidStatuses) {
      rawDb.prepare('UPDATE orders SET status = ? WHERE id = ?').run(st, activeOrder.id);

      const kot: PosKotDomain = {
        id: crypto.randomUUID(),
        order_id: activeOrder.id,
        kot_number: 2,
        status: 'printed',
        printed_at: new Date().toISOString(),
      };

      const dummyNewItem: OrderItemDomain = {
        id: crypto.randomUUID(),
        order_id: activeOrder.id,
        product_id: seeds.prod1Id,
        variant_id: null,
        product_name: 'Classic Burger',
        unit_price: 100,
        quantity: 1,
        tax_rate: 5.0,
        discount_amount: 0,
        line_total: 105,
        notes: null,
        created_at: new Date().toISOString(),
      };

      await assert.rejects(
        async () => {
          await db.appendOrderItemsAndKot(toOrderDomain(activeOrder, { status: st as any }), [dummyNewItem], kot, [{
            id: crypto.randomUUID(),
            kot_id: kot.id,
            product_id: seeds.prod1Id,
            variant_id: null,
            product_name: 'Classic Burger',
            quantity: 1,
            notes: null,
          }]);
        },
        /ORDER_STATUS_INVALID/
      );
    }
  });

  it('ADDITIONAL_KOT_EMPTY_NEW_ITEMS_REJECT_PASS — Rejects empty new item list', async () => {
    const { activeOrder } = await setupKotSentOrder();
    const kot: PosKotDomain = {
      id: crypto.randomUUID(),
      order_id: activeOrder.id,
      kot_number: 2,
      status: 'printed',
      printed_at: new Date().toISOString(),
    };

    await assert.rejects(
      async () => {
        await db.appendOrderItemsAndKot(toOrderDomain(activeOrder), [], kot, []);
      },
      /EMPTY_ITEMS/
    );
  });

  it('SENT_ORDER_ITEMS_UNCHANGED_PASS & SAME_PRODUCT_CREATES_NEW_LINE_PASS — Customer orders +1 of same Burger', async () => {
    const { activeOrder, initialItems } = await setupKotSentOrder();
    assert.equal(initialItems.length, 1);
    assert.equal(initialItems[0].quantity, 2);
    const initialItemId = initialItems[0].id;

    // Additional order: +1 of the SAME product
    const newLineId = crypto.randomUUID();
    const additionalBurgerItem: OrderItemDomain = {
      id: newLineId,
      order_id: activeOrder.id,
      product_id: seeds.prod1Id, // Same Burger!
      variant_id: null,
      product_name: 'Classic Burger',
      unit_price: 100,
      quantity: 1,
      tax_rate: 5.0,
      discount_amount: 0,
      line_total: 105,
      notes: null,
      created_at: new Date().toISOString(),
    };

    const cumulativeOrder: OrderDomain = toOrderDomain(activeOrder, {
      subtotal: 300,
      tax_total: 15,
      grand_total: 315,
    });

    const kot2Id = crypto.randomUUID();
    const kot2: PosKotDomain = {
      id: kot2Id,
      order_id: activeOrder.id,
      kot_number: 2,
      status: 'printed',
      printed_at: new Date().toISOString(),
    };

    const kot2Items: KotItemDomain[] = [{
      id: crypto.randomUUID(),
      kot_id: kot2Id,
      product_id: seeds.prod1Id,
      variant_id: null,
      product_name: 'Classic Burger',
      quantity: 1,
      notes: null,
    }];

    await db.appendOrderItemsAndKot(cumulativeOrder, [additionalBurgerItem], kot2, kot2Items);

    const fresh = await db.getActiveOrderForTable(seeds.tableId);
    assert.ok(fresh);
    assert.equal(fresh.items.length, 2, 'Must have exactly 2 distinct order_items rows');

    // Row 1: original sent item remains immutable with quantity 2
    const originalRow = fresh.items.find(i => i.id === initialItemId);
    assert.ok(originalRow);
    assert.equal(originalRow.quantity, 2, 'Historical sent item quantity remains 2');

    // Row 2: new line item with quantity 1
    const newRow = fresh.items.find(i => i.id === newLineId);
    assert.ok(newRow);
    assert.equal(newRow.quantity, 1, 'Newly appended line item has quantity 1');

    // Total ordered quantity = 3
    const totalQty = fresh.items.reduce((sum, i) => sum + i.quantity, 0);
    assert.equal(totalQty, 3, 'Cumulative quantity is 3');

    // KOT #2 items contain ONLY the newly added 1 unit
    const rawDb = (db as any).db;
    const kot2Rows = rawDb.prepare('SELECT quantity FROM kot_items WHERE kot_id = ?').all(kot2Id) as any[];
    assert.equal(kot2Rows.length, 1);
    assert.equal(kot2Rows[0].quantity, 1, 'KOT #2 ticket contains strictly quantity 1');
  });

  it('ADDITIONAL_KOT_NUMBER_TWO_PASS & THIRD_KOT_NUMBER_THREE_PASS — Monotonic KOT sequence allocation', async () => {
    const { activeOrder } = await setupKotSentOrder();

    // 1st additional KOT -> KOT #2
    const item1: OrderItemDomain = {
      id: crypto.randomUUID(),
      order_id: activeOrder.id,
      product_id: seeds.prod2Id,
      variant_id: null,
      product_name: 'Cheese Burger',
      unit_price: 150,
      quantity: 1,
      tax_rate: 5.0,
      discount_amount: 0,
      line_total: 157.5,
      notes: null,
      created_at: new Date().toISOString(),
    };
    const kot2Id = crypto.randomUUID();
    const res2 = await db.appendOrderItemsAndKot(
      toOrderDomain(activeOrder),
      [item1],
      { id: kot2Id, order_id: activeOrder.id, kot_number: 0, status: 'printed', printed_at: new Date().toISOString() },
      [{ id: crypto.randomUUID(), kot_id: kot2Id, product_id: seeds.prod2Id, variant_id: null, product_name: 'Cheese Burger', quantity: 1, notes: null }]
    );
    assert.equal(res2.kot.kot_number, 2, 'Second KOT must receive kot_number 2');

    // 2nd additional KOT -> KOT #3
    const item2: OrderItemDomain = {
      id: crypto.randomUUID(),
      order_id: activeOrder.id,
      product_id: seeds.prod1Id,
      variant_id: null,
      product_name: 'Classic Burger',
      unit_price: 100,
      quantity: 1,
      tax_rate: 5.0,
      discount_amount: 0,
      line_total: 105,
      notes: null,
      created_at: new Date().toISOString(),
    };
    const kot3Id = crypto.randomUUID();
    const res3 = await db.appendOrderItemsAndKot(
      toOrderDomain(activeOrder),
      [item2],
      { id: kot3Id, order_id: activeOrder.id, kot_number: 0, status: 'printed', printed_at: new Date().toISOString() },
      [{ id: crypto.randomUUID(), kot_id: kot3Id, product_id: seeds.prod1Id, variant_id: null, product_name: 'Classic Burger', quantity: 1, notes: null }]
    );
    assert.equal(res3.kot.kot_number, 3, 'Third KOT must receive kot_number 3');
  });

  it('SAME_OPERATION_RETRY_NO_DUPLICATE_PASS — Idempotent replay with same KOT operation ID', async () => {
    const { activeOrder } = await setupKotSentOrder();

    const newItem: OrderItemDomain = {
      id: crypto.randomUUID(),
      order_id: activeOrder.id,
      product_id: seeds.prod2Id,
      variant_id: null,
      product_name: 'Cheese Burger',
      unit_price: 150,
      quantity: 1,
      tax_rate: 5.0,
      discount_amount: 0,
      line_total: 157.5,
      notes: null,
      created_at: new Date().toISOString(),
    };

    const kotId = crypto.randomUUID();
    const kot: PosKotDomain = {
      id: kotId,
      order_id: activeOrder.id,
      kot_number: 2,
      status: 'printed',
      printed_at: new Date().toISOString(),
    };

    const kotItems: KotItemDomain[] = [{
      id: crypto.randomUUID(),
      kot_id: kotId,
      product_id: seeds.prod2Id,
      variant_id: null,
      product_name: 'Cheese Burger',
      quantity: 1,
      notes: null,
    }];

    // First execution
    const res1 = await db.appendOrderItemsAndKot(toOrderDomain(activeOrder), [newItem], kot, kotItems);
    assert.equal(res1.outboxEntries.length, 1);

    // Second execution with identical payload (retry)
    const res2 = await db.appendOrderItemsAndKot(toOrderDomain(activeOrder), [newItem], kot, kotItems);
    assert.equal(res2.kot.kot_number, 2);
    assert.equal(res2.outboxEntries.length, 0, 'No duplicate outbox row on retry');

    // Verify order_items count in SQLite is unchanged
    const fresh = await db.getActiveOrderForTable(seeds.tableId);
    assert.ok(fresh);
    assert.equal(fresh.items.length, 2, 'Items must not be duplicated on retry');
  });

  it('SAME_OPERATION_DIFFERENT_PAYLOAD_REJECT_PASS — Rejects conflicting payload on same KOT operation ID', async () => {
    const { activeOrder } = await setupKotSentOrder();

    const newItem: OrderItemDomain = {
      id: crypto.randomUUID(),
      order_id: activeOrder.id,
      product_id: seeds.prod2Id,
      variant_id: null,
      product_name: 'Cheese Burger',
      unit_price: 150,
      quantity: 1,
      tax_rate: 5.0,
      discount_amount: 0,
      line_total: 157.5,
      notes: null,
      created_at: new Date().toISOString(),
    };

    const kotId = crypto.randomUUID();
    const kot: PosKotDomain = {
      id: kotId,
      order_id: activeOrder.id,
      kot_number: 2,
      status: 'printed',
      printed_at: new Date().toISOString(),
    };

    const kotItems: KotItemDomain[] = [{
      id: crypto.randomUUID(),
      kot_id: kotId,
      product_id: seeds.prod2Id,
      variant_id: null,
      product_name: 'Cheese Burger',
      quantity: 1,
      notes: null,
    }];

    await db.appendOrderItemsAndKot(toOrderDomain(activeOrder), [newItem], kot, kotItems);

    // Conflict: same KOT ID but different quantity (2 instead of 1)
    const conflictingKotItems: KotItemDomain[] = [{
      id: kotItems[0].id,
      kot_id: kotId,
      product_id: seeds.prod2Id,
      variant_id: null,
      product_name: 'Cheese Burger',
      quantity: 2, // Conflicting!
      notes: null,
    }];

    await assert.rejects(
      async () => {
        await db.appendOrderItemsAndKot(toOrderDomain(activeOrder), [newItem], kot, conflictingKotItems);
      },
      /IDEMPOTENCY_CONFLICT/
    );
  });

  it('ADDITIONAL_KOT_ATOMIC_ROLLBACK_PASS — Failure rolls back order items, KOT, and totals', async () => {
    const { activeOrder } = await setupKotSentOrder();
    const rawDb = (db as any).db;

    const newItem: OrderItemDomain = {
      id: crypto.randomUUID(),
      order_id: activeOrder.id,
      product_id: seeds.prod2Id,
      variant_id: null,
      product_name: 'Cheese Burger',
      unit_price: 150,
      quantity: 1,
      tax_rate: 5.0,
      discount_amount: 0,
      line_total: 157.5,
      notes: null,
      created_at: new Date().toISOString(),
    };

    // Pre-insert an item with the same ID to induce a primary key collision on kot_items
    const collisionKotItemId = crypto.randomUUID();
    rawDb.prepare(`
      INSERT INTO kot_items (id, kot_id, product_id, product_name, quantity)
      VALUES (?, (SELECT id FROM pos_kots LIMIT 1), ?, 'Conflict', 1)
    `).run(collisionKotItemId, seeds.prod1Id);

    const kotId = crypto.randomUUID();
    const kot: PosKotDomain = {
      id: kotId,
      order_id: activeOrder.id,
      kot_number: 2,
      status: 'printed',
      printed_at: new Date().toISOString(),
    };

    const collidingKotItems: KotItemDomain[] = [{
      id: collisionKotItemId, // Induces UNIQUE constraint failure on kot_items
      kot_id: kotId,
      product_id: seeds.prod2Id,
      variant_id: null,
      product_name: 'Cheese Burger',
      quantity: 1,
      notes: null,
    }];

    await assert.rejects(async () => {
      await db.appendOrderItemsAndKot(toOrderDomain(activeOrder), [newItem], kot, collidingKotItems);
    });

    // Verify atomic rollback: newItem must NOT be present in order_items
    const itemInDb = rawDb.prepare('SELECT id FROM order_items WHERE id = ?').get(newItem.id);
    assert.equal(itemInDb, undefined, 'Appended order_item must be rolled back');

    const kotInDb = rawDb.prepare('SELECT id FROM pos_kots WHERE id = ?').get(kotId);
    assert.equal(kotInDb, undefined, 'KOT header must be rolled back');
  });

  describe('Task 3G.2-08A.2: Local Additional-KOT Idempotency Hardening', () => {
    async function setupAdditionalKotFixture() {
      const { session, activeOrder } = await setupKotSentOrder();

      const newItem: OrderItemDomain = {
        id: crypto.randomUUID(),
        order_id: activeOrder.id,
        product_id: seeds.prod2Id,
        variant_id: null,
        product_name: 'Cheese Burger',
        unit_price: 150,
        quantity: 1,
        tax_rate: 5.0,
        discount_amount: 0,
        line_total: 157.5,
        notes: null,
        created_at: new Date().toISOString(),
      };

      const cumulativeOrder: OrderDomain = toOrderDomain(activeOrder, {
        subtotal: 350,
        tax_total: 17.5,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 367.5,
        updated_at: new Date().toISOString(),
      });

      const kotId = crypto.randomUUID();
      const kot: PosKotDomain = {
        id: kotId,
        order_id: activeOrder.id,
        kot_number: 2,
        device_id: null,
        status: 'printed',
        printed_at: new Date().toISOString(),
      };

      const kotItems: KotItemDomain[] = [{
        id: crypto.randomUUID(),
        kot_id: kotId,
        product_id: seeds.prod2Id,
        variant_id: null,
        product_name: 'Cheese Burger',
        quantity: 1,
        notes: null,
      }];

      return { session, activeOrder, newItem, cumulativeOrder, kot, kotItems };
    }

    it('LOCAL_IDENTICAL_RETRY_PASS', async () => {
      const { cumulativeOrder, newItem, kot, kotItems } = await setupAdditionalKotFixture();
      const res1 = await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, kotItems);
      assert.equal(res1.outboxEntries.length, 1);

      const res2 = await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, kotItems);
      assert.equal(res2.outboxEntries.length, 0);
      assert.equal(res2.kot.kot_number, 2);
    });

    it('LOCAL_RETRY_CHANGED_ORDER_TOTAL_REJECT_PASS', async () => {
      const { cumulativeOrder, newItem, kot, kotItems } = await setupAdditionalKotFixture();
      await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, kotItems);

      const alteredOrder = { ...cumulativeOrder, grand_total: 999 };
      await assert.rejects(
        async () => { await db.appendOrderItemsAndKot(alteredOrder, [newItem], kot, kotItems); },
        /IDEMPOTENCY_CONFLICT.*financial totals mismatch/
      );
    });

    it('LOCAL_RETRY_CHANGED_ORDER_ITEM_PRODUCT_REJECT_PASS', async () => {
      const { cumulativeOrder, newItem, kot, kotItems } = await setupAdditionalKotFixture();
      await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, kotItems);

      const alteredItem = { ...newItem, product_id: seeds.prod1Id };
      await assert.rejects(
        async () => { await db.appendOrderItemsAndKot(cumulativeOrder, [alteredItem], kot, kotItems); },
        /IDEMPOTENCY_CONFLICT.*Order item.*attributes mismatched/
      );
    });

    it('LOCAL_RETRY_CHANGED_ORDER_ITEM_VARIANT_REJECT_PASS', async () => {
      const { cumulativeOrder, newItem, kot, kotItems } = await setupAdditionalKotFixture();
      await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, kotItems);

      const alteredItem = { ...newItem, variant_id: crypto.randomUUID() };
      await assert.rejects(
        async () => { await db.appendOrderItemsAndKot(cumulativeOrder, [alteredItem], kot, kotItems); },
        /IDEMPOTENCY_CONFLICT.*Order item.*attributes mismatched/
      );
    });

    it('LOCAL_RETRY_CHANGED_ORDER_ITEM_QUANTITY_REJECT_PASS', async () => {
      const { cumulativeOrder, newItem, kot, kotItems } = await setupAdditionalKotFixture();
      await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, kotItems);

      const alteredItem = { ...newItem, quantity: 5 };
      await assert.rejects(
        async () => { await db.appendOrderItemsAndKot(cumulativeOrder, [alteredItem], kot, kotItems); },
        /IDEMPOTENCY_CONFLICT.*Order item.*attributes mismatched/
      );
    });

    it('LOCAL_RETRY_CHANGED_ORDER_ITEM_PRICE_REJECT_PASS', async () => {
      const { cumulativeOrder, newItem, kot, kotItems } = await setupAdditionalKotFixture();
      await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, kotItems);

      const alteredItem = { ...newItem, unit_price: 250 };
      await assert.rejects(
        async () => { await db.appendOrderItemsAndKot(cumulativeOrder, [alteredItem], kot, kotItems); },
        /IDEMPOTENCY_CONFLICT.*Order item.*attributes mismatched/
      );
    });

    it('LOCAL_RETRY_CHANGED_ORDER_ITEM_TAX_REJECT_PASS', async () => {
      const { cumulativeOrder, newItem, kot, kotItems } = await setupAdditionalKotFixture();
      await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, kotItems);

      const alteredItem = { ...newItem, tax_rate: 18.0 };
      await assert.rejects(
        async () => { await db.appendOrderItemsAndKot(cumulativeOrder, [alteredItem], kot, kotItems); },
        /IDEMPOTENCY_CONFLICT.*Order item.*attributes mismatched/
      );
    });

    it('LOCAL_RETRY_CHANGED_ORDER_ITEM_DISCOUNT_REJECT_PASS', async () => {
      const { cumulativeOrder, newItem, kot, kotItems } = await setupAdditionalKotFixture();
      await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, kotItems);

      const alteredItem = { ...newItem, discount_amount: 10 };
      await assert.rejects(
        async () => { await db.appendOrderItemsAndKot(cumulativeOrder, [alteredItem], kot, kotItems); },
        /IDEMPOTENCY_CONFLICT.*Order item.*attributes mismatched/
      );
    });

    it('LOCAL_RETRY_CHANGED_ORDER_ITEM_LINE_TOTAL_REJECT_PASS', async () => {
      const { cumulativeOrder, newItem, kot, kotItems } = await setupAdditionalKotFixture();
      await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, kotItems);

      const alteredItem = { ...newItem, line_total: 999 };
      await assert.rejects(
        async () => { await db.appendOrderItemsAndKot(cumulativeOrder, [alteredItem], kot, kotItems); },
        /IDEMPOTENCY_CONFLICT.*Order item.*attributes mismatched/
      );
    });

    it('LOCAL_RETRY_CHANGED_KOT_NUMBER_REJECT_PASS', async () => {
      const { cumulativeOrder, newItem, kot, kotItems } = await setupAdditionalKotFixture();
      await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, kotItems);

      const alteredKot = { ...kot, kot_number: 99 };
      await assert.rejects(
        async () => { await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], alteredKot, kotItems); },
        /IDEMPOTENCY_CONFLICT.*has kot_number 2, retry payload has 99/
      );
    });

    it('LOCAL_RETRY_CHANGED_KOT_ITEM_PRODUCT_REJECT_PASS', async () => {
      const { cumulativeOrder, newItem, kot, kotItems } = await setupAdditionalKotFixture();
      await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, kotItems);

      const alteredKotItems = [{ ...kotItems[0], product_id: seeds.prod1Id }];
      await assert.rejects(
        async () => { await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, alteredKotItems); },
        /IDEMPOTENCY_CONFLICT.*KOT item.*mismatched/
      );
    });

    it('LOCAL_RETRY_CHANGED_KOT_ITEM_VARIANT_REJECT_PASS', async () => {
      const { cumulativeOrder, newItem, kot, kotItems } = await setupAdditionalKotFixture();
      await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, kotItems);

      const alteredKotItems = [{ ...kotItems[0], variant_id: crypto.randomUUID() }];
      await assert.rejects(
        async () => { await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, alteredKotItems); },
        /IDEMPOTENCY_CONFLICT.*KOT item.*mismatched/
      );
    });

    it('LOCAL_RETRY_CHANGED_KOT_ITEM_QUANTITY_REJECT_PASS', async () => {
      const { cumulativeOrder, newItem, kot, kotItems } = await setupAdditionalKotFixture();
      await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, kotItems);

      const alteredKotItems = [{ ...kotItems[0], quantity: 3 }];
      await assert.rejects(
        async () => { await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, alteredKotItems); },
        /IDEMPOTENCY_CONFLICT.*KOT item.*mismatched/
      );
    });

    it('LOCAL_RETRY_CHANGED_KOT_ITEM_NAME_REJECT_PASS', async () => {
      const { cumulativeOrder, newItem, kot, kotItems } = await setupAdditionalKotFixture();
      await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, kotItems);

      const alteredKotItems = [{ ...kotItems[0], product_name: 'Modified Name' }];
      await assert.rejects(
        async () => { await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, alteredKotItems); },
        /IDEMPOTENCY_CONFLICT.*KOT item.*mismatched/
      );
    });

    it('LOCAL_RETRY_CHANGED_KOT_ITEM_NOTES_REJECT_PASS', async () => {
      const { cumulativeOrder, newItem, kot, kotItems } = await setupAdditionalKotFixture();
      await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, kotItems);

      const alteredKotItems = [{ ...kotItems[0], notes: 'Extra spicy' }];
      await assert.rejects(
        async () => { await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, alteredKotItems); },
        /IDEMPOTENCY_CONFLICT.*KOT item.*mismatched/
      );
    });

    it('LOCAL_RETRY_ARRAY_REORDER_PASS', async () => {
      const { activeOrder } = await setupKotSentOrder();

      const itemA: OrderItemDomain = {
        id: crypto.randomUUID(),
        order_id: activeOrder.id,
        product_id: seeds.prod1Id,
        variant_id: null,
        product_name: 'Classic Burger',
        unit_price: 100,
        quantity: 1,
        tax_rate: 5.0,
        discount_amount: 0,
        line_total: 105,
        notes: null,
        created_at: new Date().toISOString(),
      };
      const itemB: OrderItemDomain = {
        id: crypto.randomUUID(),
        order_id: activeOrder.id,
        product_id: seeds.prod2Id,
        variant_id: null,
        product_name: 'Cheese Burger',
        unit_price: 150,
        quantity: 1,
        tax_rate: 5.0,
        discount_amount: 0,
        line_total: 157.5,
        notes: null,
        created_at: new Date().toISOString(),
      };

      const cumulativeOrder: OrderDomain = toOrderDomain(activeOrder, {
        subtotal: 450,
        tax_total: 22.5,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 472.5,
        updated_at: new Date().toISOString(),
      });

      const kotId = crypto.randomUUID();
      const kot: PosKotDomain = {
        id: kotId,
        order_id: activeOrder.id,
        kot_number: 2,
        device_id: null,
        status: 'printed',
        printed_at: new Date().toISOString(),
      };

      const kitemA: KotItemDomain = {
        id: crypto.randomUUID(),
        kot_id: kotId,
        product_id: seeds.prod1Id,
        variant_id: null,
        product_name: 'Classic Burger',
        quantity: 1,
        notes: null,
      };
      const kitemB: KotItemDomain = {
        id: crypto.randomUUID(),
        kot_id: kotId,
        product_id: seeds.prod2Id,
        variant_id: null,
        product_name: 'Cheese Burger',
        quantity: 1,
        notes: null,
      };

      // Initial execution order: [A, B]
      await db.appendOrderItemsAndKot(cumulativeOrder, [itemA, itemB], kot, [kitemA, kitemB]);

      // Retry execution order: [B, A] (reversed arrays)
      const retryResult = await db.appendOrderItemsAndKot(cumulativeOrder, [itemB, itemA], kot, [kitemB, kitemA]);
      assert.equal(retryResult.kot.kot_number, 2);
      assert.equal(retryResult.outboxEntries.length, 0);
    });

    it('LOCAL_CONFLICT_NO_EXTRA_ORDER_ITEM_PASS, LOCAL_CONFLICT_NO_EXTRA_KOT_PASS, LOCAL_CONFLICT_NO_EXTRA_OUTBOX_PASS', async () => {
      const { cumulativeOrder, newItem, kot, kotItems } = await setupAdditionalKotFixture();
      await db.appendOrderItemsAndKot(cumulativeOrder, [newItem], kot, kotItems);

      const rawDb = (db as any).db;
      const initialItemCount = (rawDb.prepare('SELECT COUNT(*) AS c FROM order_items').get() as { c: number }).c;
      const initialKotCount = (rawDb.prepare('SELECT COUNT(*) AS c FROM pos_kots').get() as { c: number }).c;
      const initialOutboxCount = (rawDb.prepare('SELECT COUNT(*) AS c FROM sync_outbox').get() as { c: number }).c;

      // Conflicting retry: changed unit price
      const alteredItem = { ...newItem, unit_price: 9999 };
      await assert.rejects(
        async () => { await db.appendOrderItemsAndKot(cumulativeOrder, [alteredItem], kot, kotItems); },
        /IDEMPOTENCY_CONFLICT/
      );

      const postItemCount = (rawDb.prepare('SELECT COUNT(*) AS c FROM order_items').get() as { c: number }).c;
      const postKotCount = (rawDb.prepare('SELECT COUNT(*) AS c FROM pos_kots').get() as { c: number }).c;
      const postOutboxCount = (rawDb.prepare('SELECT COUNT(*) AS c FROM sync_outbox').get() as { c: number }).c;

      assert.equal(postItemCount, initialItemCount, 'No extra order items on conflict');
      assert.equal(postKotCount, initialKotCount, 'No extra KOTs on conflict');
      assert.equal(postOutboxCount, initialOutboxCount, 'No extra outbox entries on conflict');
    });
  });
});
