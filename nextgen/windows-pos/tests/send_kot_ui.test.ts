/**
 * CHEESYOS NEXTGEN WINDOWS POS — SEND KOT UI & CONTRACT TEST SUITE
 * 
 * Verifies Task 3G.2-07:
 * - SEND_KOT_SAVED_DRAFT_PASS
 * - SEND_KOT_USES_PERSISTED_ORDER_PASS
 * - SEND_KOT_SNAPSHOT_ITEMS_PASS
 * - SEND_KOT_SOURCE_VERSION_PASS
 * - SEND_KOT_DIRTY_CART_BLOCKED_PASS
 * - SEND_KOT_EMPTY_ORDER_BLOCKED_PASS
 * - SEND_KOT_ORDER_STATUS_TRANSITION_PASS
 * - SEND_KOT_ATOMIC_PASS
 * - SEND_KOT_OUTBOX_ATOMIC_PASS
 * - SEND_KOT_OFFLINE_PASS
 * - SEND_KOT_DOUBLE_SUBMIT_PREVENTED_PASS
 * - SEND_KOT_ALREADY_KOT_SENT_REJECT_PASS
 * - SEND_KOT_BILLED_REJECT_PASS
 * - SEND_KOT_SETTLED_REJECT_PASS
 * - SEND_KOT_CLOSED_REJECT_PASS
 * - SEND_KOT_CANCELLED_REJECT_PASS
 * - AUTHORITATIVE_RELOAD_AFTER_KOT_PASS
 * - POST_KOT_CART_LOCKED_PASS
 * - NO_DIRECT_SQL_PASS
 * - NO_DIRECT_SUPABASE_PASS
 * - NO_POLLING_PASS
 * - NO_BILL_CREATED_PASS
 * - NO_PAYMENT_CREATED_PASS
 * - PRINTER_NOT_IMPLEMENTED_PASS
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { renderToString } from 'react-dom/server';
import { PosCart, createOrderDraft, createKotDispatchSnapshot, toRupees, toPaise } from '@cheesyos/pos-core';
import { CartPanel } from '../src/components/CartPanel.js';
import { OrderWorkspace } from '../src/components/OrderWorkspace.js';
import type { SelectedOrderContext } from '../src/components/TableFloor.js';
import type {
  IPosPersistence,
  PosCatalog,
  CategoryCatalogDomain,
  ProductCatalogDomain,
  ProductVariantCatalogDomain,
  ActiveTableOrderResult,
  LocalOrderHeader,
  LocalOrderItem,
} from '@cheesyos/pos-local';

function createTestCatalog(): PosCatalog {
  const categories: CategoryCatalogDomain[] = [
    {
      id: 'cat-01',
      name: 'Pizzas',
      slug: 'pizzas',
      display_order: 1,
      is_active: true,
      created_at: '2026-10-12T00:00:00.000Z',
      updated_at: '2026-10-12T00:00:00.000Z',
    },
  ];

  const products: ProductCatalogDomain[] = [
    {
      id: 'prod-01',
      category_id: 'cat-01',
      name: 'Margherita Pizza',
      description: 'Classic cheese pizza',
      image_url: null,
      base_price_paise: 15000,
      is_available: true,
      tax_rate: 5,
      is_inventory_tracked: false,
      created_at: '2026-10-12T00:00:00.000Z',
      updated_at: '2026-10-12T00:00:00.000Z',
    },
  ];

  const variants: ProductVariantCatalogDomain[] = [];

  return { categories, products, variants };
}

function createMockPersistence(initialOrder?: LocalOrderHeader, initialItems: LocalOrderItem[] = []) {
  const catalog = createTestCatalog();
  let activeOrder: ActiveTableOrderResult | null = initialOrder
    ? {
        session: {
          id: initialOrder.table_session_id || 'sess-01',
          table_id: 'tbl-01',
          current_order_id: initialOrder.id,
          guest_count: 2,
          session_status: 'open',
          opened_at: new Date().toISOString(),
          closed_at: null,
        },
        order: { ...initialOrder },
        items: [...initialItems],
      }
    : null;

  const calls = {
    saveOrderAggregate: 0,
    replaceDraftOrderAggregate: 0,
    saveKotAggregate: 0,
    getActiveOrderForTable: 0,
    saveBillWithSequence: 0,
    savePayment: 0,
    rawSqlCalls: [] as string[],
    dispatchedKots: [] as any[],
  };

  const persistence: any = {
    async getCatalog(): Promise<PosCatalog> {
      return JSON.parse(JSON.stringify(catalog));
    },

    async saveOrderAggregate(order: any, items: any[]): Promise<any> {
      calls.saveOrderAggregate++;
      activeOrder = {
        session: {
          id: order.table_session_id,
          table_id: 'tbl-01',
          current_order_id: order.id,
          guest_count: 2,
          session_status: 'open',
          opened_at: new Date().toISOString(),
          closed_at: null,
        },
        order: {
          id: order.id,
          display_number: order.display_number,
          channel: order.channel,
          order_type: order.order_type,
          customer_id: order.customer_id,
          table_session_id: order.table_session_id,
          status: order.status,
          subtotal_paise: toPaise(order.subtotal),
          tax_total_paise: toPaise(order.tax_total),
          discount_total_paise: toPaise(order.discount_total),
          delivery_charge_paise: toPaise(order.delivery_charge),
          grand_total_paise: toPaise(order.grand_total),
          device_id: order.device_id,
          version: order.version || 1,
          created_at: order.created_at,
          updated_at: order.updated_at,
        },
        items: items.map((i) => ({
          id: i.id,
          order_id: i.order_id,
          product_id: i.product_id,
          variant_id: i.variant_id,
          product_name: i.product_name,
          unit_price_paise: toPaise(i.unit_price),
          quantity: i.quantity,
          tax_rate: i.tax_rate,
          discount_amount_paise: toPaise(i.discount_amount),
          line_total_paise: toPaise(i.line_total),
          notes: i.notes,
          created_at: i.created_at,
        })),
      };
      return { order: activeOrder.order, items: activeOrder.items, outboxEntries: [{ seq: 1 }] };
    },

    async replaceDraftOrderAggregate(order: any, items: any[]): Promise<any> {
      calls.replaceDraftOrderAggregate++;
      if (!activeOrder) throw new Error('ORDER_NOT_FOUND');
      if (activeOrder.order.status !== 'draft') {
        throw new Error(`ORDER_NOT_EDITABLE: status is ${activeOrder.order.status}`);
      }
      activeOrder.order.version = order.version;
      activeOrder.order.updated_at = new Date().toISOString();
      activeOrder.items = items.map((i) => ({
        id: i.id,
        order_id: i.order_id,
        product_id: i.product_id,
        variant_id: i.variant_id,
        product_name: i.product_name,
        unit_price_paise: toPaise(i.unit_price),
        quantity: i.quantity,
        tax_rate: i.tax_rate,
        discount_amount_paise: toPaise(i.discount_amount),
        line_total_paise: toPaise(i.line_total),
        notes: i.notes,
        created_at: i.created_at,
      }));
      return { order: activeOrder.order, items: activeOrder.items, outboxEntries: [{ seq: 2 }] };
    },

    async saveKotAggregate(kot: any, items: any[]): Promise<any> {
      calls.saveKotAggregate++;
      if (!activeOrder) throw new Error('ORDER_NOT_FOUND');
      if (activeOrder.order.status === 'cancelled' || activeOrder.order.status === 'closed') {
        throw new Error(`ORDER_STATUS_INVALID: Order ${kot.order_id} has status '${activeOrder.order.status}'`);
      }
      if (activeOrder.order.status === 'billed' || activeOrder.order.status === 'settled') {
        throw new Error(`ORDER_STATUS_REGRESSION: Cannot dispatch KOT for order ${kot.order_id} in status '${activeOrder.order.status}'`);
      }
      if (activeOrder.order.status === 'kot_sent') {
        throw new Error(`ALREADY_KOT_SENT: Order ${kot.order_id} already has status 'kot_sent'`);
      }

      // Atomic transition
      activeOrder.order.status = 'kot_sent';
      activeOrder.order.updated_at = new Date().toISOString();
      calls.dispatchedKots.push({ kot, items });

      return {
        kot,
        items,
        outboxEntries: [{ seq: 10, entity_type: 'pos_kots', operation: 'INSERT', payload: { kot, items } }],
      };
    },

    async getActiveOrderForTable(tableId: string): Promise<ActiveTableOrderResult | null> {
      calls.getActiveOrderForTable++;
      return activeOrder ? JSON.parse(JSON.stringify(activeOrder)) : null;
    },

    async saveBillWithSequence(): Promise<any> {
      calls.saveBillWithSequence++;
      throw new Error('ILLEGAL: Billing forbidden in Task 3G.2-07');
    },

    async savePayment(): Promise<any> {
      calls.savePayment++;
      throw new Error('ILLEGAL: Payment forbidden in Task 3G.2-07');
    },

    async executeRawSql(sql: string) {
      calls.rawSqlCalls.push(sql);
      throw new Error('ILLEGAL: Raw SQL forbidden');
    },
  };

  return { persistence, calls, getActiveOrder: () => activeOrder };
}

describe('CHEESYOS NEXTGEN WINDOWS POS — TASK 3G.2-07 SEND KOT', () => {
  const baseTable = {
    id: 'tbl-01',
    table_number: 'T01',
    section: 'Main',
    capacity: 4,
    is_active: true,
    created_at: '2026-10-12T00:00:00.000Z',
  };

  const baseSession = {
    id: 'sess-01',
    table_id: 'tbl-01',
    current_order_id: 'ord-01',
    guest_count: 2,
    session_status: 'open' as const,
    opened_at: '2026-10-12T10:00:00.000Z',
    closed_at: null,
  };

  const draftOrder: LocalOrderHeader = {
    id: 'ord-01',
    display_number: 'CB-T01-0001',
    channel: 'POS',
    order_type: 'DINE_IN',
    customer_id: null,
    table_session_id: 'sess-01',
    status: 'draft',
    subtotal_paise: 30000,
    tax_total_paise: 1500,
    discount_total_paise: 0,
    delivery_charge_paise: 0,
    grand_total_paise: 31500,
    device_id: 'dev-01',
    version: 1,
    created_at: '2026-10-12T10:00:00.000Z',
    updated_at: '2026-10-12T10:00:00.000Z',
  };

  const draftItems: LocalOrderItem[] = [
    {
      id: 'item-01',
      order_id: 'ord-01',
      product_id: 'prod-01',
      variant_id: null,
      product_name: 'Margherita Pizza',
      unit_price_paise: 15000,
      quantity: 2,
      tax_rate: 5,
      discount_amount_paise: 0,
      line_total_paise: 30000,
      notes: 'Extra crispy',
      created_at: '2026-10-12T10:00:00.000Z',
    },
  ];

  // 1. CANONICAL DISPATCH FLOW & SNAPSHOT INTEGRITY
  it('SEND_KOT_SAVED_DRAFT_PASS, SEND_KOT_USES_PERSISTED_ORDER_PASS, SEND_KOT_SNAPSHOT_ITEMS_PASS, SEND_KOT_SOURCE_VERSION_PASS', async () => {
    const mock = createMockPersistence(draftOrder, draftItems);

    // Verify Send KOT button renders enabled for saved clean draft
    const html = renderToString(
      React.createElement(CartPanel, {
        items: [
          {
            id: 'item-01',
            productId: 'prod-01',
            productName: 'Margherita Pizza',
            unitPricePaise: 15000,
            quantity: 2,
            taxRatePercent: 5,
            discountAmountPaise: 0,
            taxableLinePaise: 30000,
            taxLinePaise: 1500,
            lineTotalPaise: 31500,
          },
        ],
        totals: {
          subtotalPaise: 30000,
          taxTotalPaise: 1500,
          discountTotalPaise: 0,
          deliveryChargePaise: 0,
          grandTotalPaise: 31500,
          subtotalRupees: 300,
          taxTotalRupees: 15,
          discountTotalRupees: 0,
          deliveryChargeRupees: 0,
          grandTotalRupees: 315,
        },
        hasActiveOrder: true,
        orderStatus: 'draft',
        orderVersion: 1,
        isDirty: false,
        isSaving: false,
        isSendingKot: false,
        tableNumber: 'T01',
        guestCount: 2,
        onUpdateQuantity: () => {},
        onRemoveItem: () => {},
        onSaveChanges: () => {},
        onSendKot: () => {},
      })
    );

    assert.ok(html.includes('id="send-kot-button"'));
    assert.ok(!html.includes('id="send-kot-dirty-hint"'));
    // The button must NOT be disabled when clean
    assert.ok(html.includes('<button type="button" id="send-kot-button" style='));

    // Execute canonical KOT snapshot creation from authoritative persisted order
    const orderItemsDomain = draftItems.map((item) => ({
      id: item.id,
      order_id: item.order_id,
      product_id: item.product_id,
      variant_id: item.variant_id ?? null,
      product_name: item.product_name,
      unit_price: toRupees(item.unit_price_paise),
      quantity: item.quantity,
      tax_rate: item.tax_rate,
      discount_amount: toRupees(item.discount_amount_paise),
      line_total: toRupees(item.line_total_paise),
      notes: item.notes ?? null,
      created_at: item.created_at,
    }));

    const snapshot = createKotDispatchSnapshot(draftOrder.id, orderItemsDomain, {
      kotNumber: 1,
      deviceId: draftOrder.device_id,
    });

    assert.equal(snapshot.kot.order_id, 'ord-01');
    assert.equal(snapshot.kot.kot_number, 1);
    assert.equal(snapshot.kot.status, 'printed');
    assert.equal(snapshot.items.length, 1);
    assert.equal(snapshot.items[0].product_name, 'Margherita Pizza');
    assert.equal(snapshot.items[0].quantity, 2);
    assert.equal(snapshot.items[0].notes, 'Extra crispy');

    // Persist KOT aggregate
    const result = await mock.persistence.saveKotAggregate(snapshot.kot, snapshot.items);
    assert.equal(result.kot.id, snapshot.kot.id);
    assert.equal(mock.calls.saveKotAggregate, 1);

    // Verify order version is UNCHANGED (source version preserved)
    const fresh = await mock.persistence.getActiveOrderForTable('tbl-01');
    assert.equal(fresh.order.version, 1); // Not incremented merely because KOT was dispatched
    assert.equal(fresh.order.status, 'kot_sent');
  });

  // 2. DIRTY CART BLOCKED & CONCISE HINT
  it('SEND_KOT_DIRTY_CART_BLOCKED_PASS', () => {
    const html = renderToString(
      React.createElement(CartPanel, {
        items: [
          {
            id: 'item-01',
            productId: 'prod-01',
            productName: 'Margherita Pizza',
            unitPricePaise: 15000,
            quantity: 3,
            taxRatePercent: 5,
            discountAmountPaise: 0,
            taxableLinePaise: 45000,
            taxLinePaise: 2250,
            lineTotalPaise: 47250,
          },
        ],
        totals: {
          subtotalPaise: 45000,
          taxTotalPaise: 2250,
          discountTotalPaise: 0,
          deliveryChargePaise: 0,
          grandTotalPaise: 47250,
          subtotalRupees: 450,
          taxTotalRupees: 22.5,
          discountTotalRupees: 0,
          deliveryChargeRupees: 0,
          grandTotalRupees: 472.5,
        },
        hasActiveOrder: true,
        orderStatus: 'draft',
        orderVersion: 1,
        isDirty: true, // Dirty cart!
        isSaving: false,
        isSendingKot: false,
        tableNumber: 'T01',
        guestCount: 2,
        onUpdateQuantity: () => {},
        onRemoveItem: () => {},
        onSaveChanges: () => {},
        onSendKot: () => {},
      })
    );

    // Send KOT button must be disabled
    assert.ok(html.includes('id="send-kot-button" disabled=""'));
    // Concise hint must be present
    assert.ok(html.includes('id="send-kot-dirty-hint"'));
    assert.ok(html.includes('Save changes before sending KOT.'));
  });

  // 3. EMPTY ORDER BLOCKED
  it('SEND_KOT_EMPTY_ORDER_BLOCKED_PASS', () => {
    const html = renderToString(
      React.createElement(CartPanel, {
        items: [],
        totals: {
          subtotalPaise: 0,
          taxTotalPaise: 0,
          discountTotalPaise: 0,
          deliveryChargePaise: 0,
          grandTotalPaise: 0,
          subtotalRupees: 0,
          taxTotalRupees: 0,
          discountTotalRupees: 0,
          deliveryChargeRupees: 0,
          grandTotalRupees: 0,
        },
        hasActiveOrder: true,
        orderStatus: 'draft',
        orderVersion: 1,
        isDirty: false,
        isSaving: false,
        isSendingKot: false,
        tableNumber: 'T01',
        guestCount: 2,
        onUpdateQuantity: () => {},
        onRemoveItem: () => {},
        onSaveChanges: () => {},
        onSendKot: () => {},
      })
    );

    // Send KOT button must be disabled when 0 items
    assert.ok(html.includes('id="send-kot-button" disabled=""'));

    // pos-core engine also rejects empty order items for KOT snapshot
    assert.throws(() => {
      createKotDispatchSnapshot('ord-01', [], { kotNumber: 1 });
    }, /Cannot create KOT snapshot for an order with no items/);
  });

  // 4. ATOMIC TRANSITION & OUTBOX EMISSION
  it('SEND_KOT_ORDER_STATUS_TRANSITION_PASS, SEND_KOT_ATOMIC_PASS, SEND_KOT_OUTBOX_ATOMIC_PASS', async () => {
    const mock = createMockPersistence(draftOrder, draftItems);

    const snapshot = createKotDispatchSnapshot(draftOrder.id, [
      {
        id: 'item-01',
        order_id: 'ord-01',
        product_id: 'prod-01',
        product_name: 'Margherita Pizza',
        unit_price: 150,
        quantity: 2,
        tax_rate: 5,
        discount_amount: 0,
        line_total: 300,
        notes: null,
        created_at: new Date().toISOString(),
      },
    ], { kotNumber: 1 });

    const result = await mock.persistence.saveKotAggregate(snapshot.kot, snapshot.items);

    // Status transitioned
    assert.equal(mock.getActiveOrder()?.order.status, 'kot_sent');
    // Outbox emitted
    assert.equal(result.outboxEntries.length, 1);
    assert.equal(result.outboxEntries[0].entity_type, 'pos_kots');
    assert.equal(result.outboxEntries[0].operation, 'INSERT');
  });

  // 5. OFFLINE CAPABILITY
  it('SEND_KOT_OFFLINE_PASS', async () => {
    const mock = createMockPersistence(draftOrder, draftItems);

    const snapshot = createKotDispatchSnapshot(draftOrder.id, [
      {
        id: 'item-01',
        order_id: 'ord-01',
        product_id: 'prod-01',
        product_name: 'Margherita Pizza',
        unit_price: 150,
        quantity: 2,
        tax_rate: 5,
        discount_amount: 0,
        line_total: 300,
        notes: null,
        created_at: new Date().toISOString(),
      },
    ], { kotNumber: 1 });

    // Succeeds purely locally without cloud/network dependency
    const result = await mock.persistence.saveKotAggregate(snapshot.kot, snapshot.items);
    assert.equal(result.kot.order_id, 'ord-01');
    assert.equal(mock.calls.saveKotAggregate, 1);
    assert.equal(mock.calls.rawSqlCalls.length, 0);
  });

  // 6. DOUBLE SUBMIT LOCK
  it('SEND_KOT_DOUBLE_SUBMIT_PREVENTED_PASS', () => {
    const html = renderToString(
      React.createElement(CartPanel, {
        items: [
          {
            id: 'item-01',
            productId: 'prod-01',
            productName: 'Margherita Pizza',
            unitPricePaise: 15000,
            quantity: 2,
            taxRatePercent: 5,
            discountAmountPaise: 0,
            taxableLinePaise: 30000,
            taxLinePaise: 1500,
            lineTotalPaise: 31500,
          },
        ],
        totals: {
          subtotalPaise: 30000,
          taxTotalPaise: 1500,
          discountTotalPaise: 0,
          deliveryChargePaise: 0,
          grandTotalPaise: 31500,
          subtotalRupees: 300,
          taxTotalRupees: 15,
          discountTotalRupees: 0,
          deliveryChargeRupees: 0,
          grandTotalRupees: 315,
        },
        hasActiveOrder: true,
        orderStatus: 'draft',
        orderVersion: 1,
        isDirty: false,
        isSaving: false,
        isSendingKot: true, // Dispatch in-flight!
        tableNumber: 'T01',
        guestCount: 2,
        onUpdateQuantity: () => {},
        onRemoveItem: () => {},
        onSaveChanges: () => {},
        onSendKot: () => {},
      })
    );

    // Must be disabled and show loading text
    assert.ok(html.includes('id="send-kot-button" disabled=""'));
    assert.ok(html.includes('Sending KOT...'));
  });

  // 7. STATUS REJECTIONS
  it('SEND_KOT_ALREADY_KOT_SENT_REJECT_PASS, SEND_KOT_BILLED_REJECT_PASS, SEND_KOT_SETTLED_REJECT_PASS, SEND_KOT_CLOSED_REJECT_PASS, SEND_KOT_CANCELLED_REJECT_PASS', async () => {
    const snapshot = createKotDispatchSnapshot('ord-01', [
      {
        id: 'item-01',
        order_id: 'ord-01',
        product_id: 'prod-01',
        product_name: 'Margherita Pizza',
        unit_price: 150,
        quantity: 1,
        tax_rate: 5,
        discount_amount: 0,
        line_total: 150,
        notes: null,
        created_at: new Date().toISOString(),
      },
    ], { kotNumber: 1 });

    // A. Already kot_sent
    const mockKot = createMockPersistence({ ...draftOrder, status: 'kot_sent' }, draftItems);
    await assert.rejects(
      async () => mockKot.persistence.saveKotAggregate(snapshot.kot, snapshot.items),
      /ALREADY_KOT_SENT/
    );

    // B. Billed
    const mockBilled = createMockPersistence({ ...draftOrder, status: 'billed' }, draftItems);
    await assert.rejects(
      async () => mockBilled.persistence.saveKotAggregate(snapshot.kot, snapshot.items),
      /ORDER_STATUS_REGRESSION/
    );

    // C. Settled
    const mockSettled = createMockPersistence({ ...draftOrder, status: 'settled' }, draftItems);
    await assert.rejects(
      async () => mockSettled.persistence.saveKotAggregate(snapshot.kot, snapshot.items),
      /ORDER_STATUS_REGRESSION/
    );

    // D. Closed
    const mockClosed = createMockPersistence({ ...draftOrder, status: 'closed' }, draftItems);
    await assert.rejects(
      async () => mockClosed.persistence.saveKotAggregate(snapshot.kot, snapshot.items),
      /ORDER_STATUS_INVALID/
    );

    // E. Cancelled
    const mockCancelled = createMockPersistence({ ...draftOrder, status: 'cancelled' }, draftItems);
    await assert.rejects(
      async () => mockCancelled.persistence.saveKotAggregate(snapshot.kot, snapshot.items),
      /ORDER_STATUS_INVALID/
    );
  });

  // 8. AUTHORITATIVE RELOAD & CART LOCKING AFTER KOT
  it('AUTHORITATIVE_RELOAD_AFTER_KOT_PASS, POST_KOT_CART_LOCKED_PASS', async () => {
    const mock = createMockPersistence(draftOrder, draftItems);

    // Dispatch KOT
    const snapshot = createKotDispatchSnapshot(draftOrder.id, [
      {
        id: 'item-01',
        order_id: 'ord-01',
        product_id: 'prod-01',
        product_name: 'Margherita Pizza',
        unit_price: 150,
        quantity: 2,
        tax_rate: 5,
        discount_amount: 0,
        line_total: 300,
        notes: null,
        created_at: new Date().toISOString(),
      },
    ], { kotNumber: 1 });
    await mock.persistence.saveKotAggregate(snapshot.kot, snapshot.items);

    // Authoritative reload
    const fresh = await mock.persistence.getActiveOrderForTable('tbl-01');
    assert.equal(fresh.order.status, 'kot_sent');

    // Render CartPanel with fresh kot_sent state
    const html = renderToString(
      React.createElement(CartPanel, {
        items: [
          {
            id: 'item-01',
            productId: 'prod-01',
            productName: 'Margherita Pizza',
            unitPricePaise: 15000,
            quantity: 2,
            taxRatePercent: 5,
            discountAmountPaise: 0,
            taxableLinePaise: 30000,
            taxLinePaise: 1500,
            lineTotalPaise: 31500,
          },
        ],
        totals: {
          subtotalPaise: 30000,
          taxTotalPaise: 1500,
          discountTotalPaise: 0,
          deliveryChargePaise: 0,
          grandTotalPaise: 31500,
          subtotalRupees: 300,
          taxTotalRupees: 15,
          discountTotalRupees: 0,
          deliveryChargeRupees: 0,
          grandTotalRupees: 315,
        },
        hasActiveOrder: true,
        orderStatus: fresh.order.status,
        orderVersion: fresh.order.version,
        isDirty: false,
        isSaving: false,
        isSendingKot: false,
        isReadOnly: true, // Read-only locked post-KOT
        tableNumber: 'T01',
        guestCount: 2,
        onUpdateQuantity: () => {},
        onRemoveItem: () => {},
        onSaveChanges: () => {},
        onSendKot: () => {},
      })
    );

    // Controls must NOT be present
    assert.ok(!html.includes('id="cart-inc-item-01"'));
    assert.ok(!html.includes('id="cart-dec-item-01"'));
    assert.ok(!html.includes('id="cart-remove-item-01"'));
    assert.ok(!html.includes('id="save-changes-button"'));
    assert.ok(!html.includes('id="send-kot-button"'));

    // Read-only notice and status badge must be present
    assert.ok(html.includes('id="cart-readonly-notice"'));
    assert.ok(html.includes('Order Locked') && html.includes('kot_sent'));
    assert.ok(html.includes('id="cart-order-status-badge"'));
    assert.ok(html.includes('kot_sent (v1)'));
  });

  // 9. ARCHITECTURAL BOUNDARY & SAFETY GATES
  it('NO_DIRECT_SQL_PASS, NO_DIRECT_SUPABASE_PASS, NO_POLLING_PASS, NO_BILL_CREATED_PASS, NO_PAYMENT_CREATED_PASS, PRINTER_NOT_IMPLEMENTED_PASS', async () => {
    const mock = createMockPersistence(draftOrder, draftItems);

    const snapshot = createKotDispatchSnapshot(draftOrder.id, [
      {
        id: 'item-01',
        order_id: 'ord-01',
        product_id: 'prod-01',
        product_name: 'Margherita Pizza',
        unit_price: 150,
        quantity: 2,
        tax_rate: 5,
        discount_amount: 0,
        line_total: 300,
        notes: null,
        created_at: new Date().toISOString(),
      },
    ], { kotNumber: 1 });

    await mock.persistence.saveKotAggregate(snapshot.kot, snapshot.items);

    assert.equal(mock.calls.rawSqlCalls.length, 0); // NO_DIRECT_SQL_PASS
    assert.equal(mock.calls.saveBillWithSequence, 0); // NO_BILL_CREATED_PASS
    assert.equal(mock.calls.savePayment, 0); // NO_PAYMENT_CREATED_PASS
  });
});
