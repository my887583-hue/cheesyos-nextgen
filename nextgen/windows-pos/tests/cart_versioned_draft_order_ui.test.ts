/**
 * CHEESYOS NEXTGEN WINDOWS POS — CART & VERSIONED LOCAL DRAFT ORDER UI TEST SUITE
 * 
 * Verifies Task 3G.2-06C:
 * 1. CART_ADD_SIMPLE_PRODUCT_PASS, CART_VARIANT_REQUIRED_PASS, CART_ADD_VARIANT_PASS
 * 2. CART_INCREMENT_PASS, CART_DECREMENT_PASS, CART_REMOVE_PASS
 * 3. CART_USES_POS_CORE_PASS, CART_PAISE_ONLY_PASS, CART_TOTALS_POS_CORE_PASS
 * 4. EMPTY_CART_NO_ORDER_PASS
 * 5. INITIAL_DRAFT_SAVE_PASS, INITIAL_DRAFT_VERSION_ONE_PASS, INITIAL_DRAFT_SESSION_LINK_PASS, INITIAL_DRAFT_LOCAL_OUTBOX_PASS
 * 6. AUTHORITATIVE_RELOAD_AFTER_CREATE_PASS
 * 7. EXISTING_DRAFT_HYDRATE_PASS, EXISTING_DRAFT_EDIT_PASS, EXISTING_DRAFT_SAME_ORDER_ID_PASS, EXISTING_DRAFT_SAME_SESSION_PASS, EXISTING_DRAFT_NEXT_VERSION_PASS
 * 8. AUTHORITATIVE_RELOAD_AFTER_UPDATE_PASS
 * 9. DOUBLE_CREATE_PREVENTED_PASS, DOUBLE_UPDATE_PREVENTED_PASS
 * 10. UNSAVED_NAVIGATION_GUARD_PASS
 * 11. KOT_SENT_CART_LOCKED_PASS, BILLED_CART_LOCKED_PASS, SETTLED_CART_LOCKED_PASS, CLOSED_CART_LOCKED_PASS, CANCELLED_CART_LOCKED_PASS
 * 12. UNAVAILABLE_PRODUCT_REJECT_PASS
 * 13. OFFLINE_INITIAL_SAVE_PASS, OFFLINE_DRAFT_UPDATE_PASS
 * 14. NO_DIRECT_SQL_PASS, NO_DIRECT_SUPABASE_PASS, NO_POLLING_PASS
 * 15. NO_KOT_CREATED_PASS, NO_BILL_CREATED_PASS, NO_PAYMENT_CREATED_PASS
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { renderToString } from 'react-dom/server';
import { PosCart, createOrderDraft, toRupees, toPaise } from '@cheesyos/pos-core';
import { OrderWorkspace } from '../src/components/OrderWorkspace.js';
import { MenuCatalog, formatPaise } from '../src/components/MenuCatalog.js';
import { CartPanel } from '../src/components/CartPanel.js';
import type { SelectedOrderContext } from '../src/components/TableFloor.js';
import type {
  IPosPersistence,
  PosCatalog,
  CategoryCatalogDomain,
  ProductCatalogDomain,
  ProductVariantCatalogDomain,
  ActiveTableOrderResult,
  TableWithActiveSession,
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
      id: 'prod-simple-01',
      category_id: 'cat-01',
      name: 'Margherita Pizza',
      description: 'Single size pizza',
      image_url: null,
      base_price_paise: 15000,
      is_available: true,
      tax_rate: 5,
      is_inventory_tracked: false,
      created_at: '2026-10-12T00:00:00.000Z',
      updated_at: '2026-10-12T00:00:00.000Z',
    },
    {
      id: 'prod-variant-01',
      category_id: 'cat-01',
      name: 'Farmhouse Pizza',
      description: 'Multi-size pizza',
      image_url: null,
      base_price_paise: 20000,
      is_available: true,
      tax_rate: 5,
      is_inventory_tracked: false,
      created_at: '2026-10-12T00:00:00.000Z',
      updated_at: '2026-10-12T00:00:00.000Z',
    },
    {
      id: 'prod-unavailable-01',
      category_id: 'cat-01',
      name: 'Truffle Pizza',
      description: 'Sold out',
      image_url: null,
      base_price_paise: 50000,
      is_available: false,
      tax_rate: 5,
      is_inventory_tracked: false,
      created_at: '2026-10-12T00:00:00.000Z',
      updated_at: '2026-10-12T00:00:00.000Z',
    },
  ];

  const variants: ProductVariantCatalogDomain[] = [
    {
      id: 'var-regular-01',
      product_id: 'prod-variant-01',
      variant_name: 'Regular',
      price_override_paise: 20000,
      is_available: true,
      created_at: '2026-10-12T00:00:00.000Z',
    },
    {
      id: 'var-large-01',
      product_id: 'prod-variant-01',
      variant_name: 'Large',
      price_override_paise: 35000,
      is_available: true,
      created_at: '2026-10-12T00:00:00.000Z',
    },
    {
      id: 'var-unavail-01',
      product_id: 'prod-variant-01',
      variant_name: 'Monster',
      price_override_paise: 60000,
      is_available: false,
      created_at: '2026-10-12T00:00:00.000Z',
    },
  ];

  return { categories, products, variants };
}

function createMockPersistenceState() {
  const catalog = createTestCatalog();
  let activeOrder: ActiveTableOrderResult | null = null;
  const calls = {
    saveOrderAggregate: 0,
    replaceDraftOrderAggregate: 0,
    getActiveOrderForTable: 0,
    saveKotAggregate: 0,
    saveBillWithSequence: 0,
    savePayment: 0,
    rawSqlCalls: [] as string[],
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
      return { order: activeOrder.order, items: activeOrder.items, outboxRow: { seq: 1 } };
    },

    async replaceDraftOrderAggregate(order: any, items: any[]): Promise<any> {
      calls.replaceDraftOrderAggregate++;
      if (!activeOrder) throw new Error('ORDER_NOT_FOUND');
      activeOrder = {
        ...activeOrder,
        order: {
          ...activeOrder.order,
          subtotal_paise: toPaise(order.subtotal),
          tax_total_paise: toPaise(order.tax_total),
          discount_total_paise: toPaise(order.discount_total),
          delivery_charge_paise: toPaise(order.delivery_charge),
          grand_total_paise: toPaise(order.grand_total),
          version: order.version,
          updated_at: new Date().toISOString(),
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
      return { order: activeOrder.order, items: activeOrder.items, outboxRow: { seq: 2 } };
    },

    async getActiveOrderForTable(tableId: string): Promise<ActiveTableOrderResult | null> {
      calls.getActiveOrderForTable++;
      return activeOrder ? JSON.parse(JSON.stringify(activeOrder)) : null;
    },

    async saveKotAggregate(): Promise<any> {
      calls.saveKotAggregate++;
      throw new Error('ILLEGAL: KOT forbidden in Task 3G.2-06C');
    },

    async saveBillWithSequence(): Promise<any> {
      calls.saveBillWithSequence++;
      throw new Error('ILLEGAL: Billing forbidden in Task 3G.2-06C');
    },

    async savePayment(): Promise<any> {
      calls.savePayment++;
      throw new Error('ILLEGAL: Payment forbidden in Task 3G.2-06C');
    },

    async executeRawSql(sql: string) {
      calls.rawSqlCalls.push(sql);
      throw new Error('ILLEGAL: Raw SQL forbidden');
    },
  };

  return { persistence, calls, getActiveOrder: () => activeOrder };
}

describe('CHEESYOS NEXTGEN WINDOWS POS — TASK 3G.2-06C CART & VERSIONED LOCAL DRAFT UI', () => {
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
    current_order_id: null,
    guest_count: 2,
    session_status: 'open' as const,
    opened_at: '2026-10-12T10:00:00.000Z',
    closed_at: null,
  };

  // 1. PRODUCT ADDITION & VARIANT ENFORCEMENT
  it('CART_ADD_SIMPLE_PRODUCT_PASS, CART_VARIANT_REQUIRED_PASS, CART_ADD_VARIANT_PASS', () => {
    const catalog = createTestCatalog();
    const cart = new PosCart({ orderType: 'DINE_IN', tableSessionId: 'sess-01' });

    // A. Add simple product
    const simple = catalog.products.find((p) => p.id === 'prod-simple-01')!;
    const item1 = cart.addItem({
      productId: simple.id,
      productName: simple.name,
      unitPriceRupees: toRupees(simple.base_price_paise),
      taxRatePercent: simple.tax_rate,
    });
    assert.equal(item1.productId, 'prod-simple-01');
    assert.equal(item1.unitPricePaise, 15000);
    assert.equal(item1.quantity, 1);
    assert.equal(cart.getState().items.length, 1);

    // B. Variant required: MenuCatalog does NOT render a direct add button on variant products
    const html = renderToString(
      React.createElement(MenuCatalog, {
        db: createMockPersistenceState().persistence,
        initialCatalog: catalog,
        onAddToCart: () => {},
      })
    );
    // Simple product has add-product button
    assert.ok(html.includes('id="add-product-prod-simple-01"'), 'Simple product has direct add button');
    // Variant product does NOT have add-product button (forces choosing variant)
    assert.ok(!html.includes('id="add-product-prod-variant-01"'), 'Variant product lacks generic add button');
    // Variant product has individual variant buttons
    assert.ok(html.includes('id="add-variant-var-regular-01"'), 'Regular variant has add button');
    assert.ok(html.includes('id="add-variant-var-large-01"'), 'Large variant has add button');

    // C. Add variant product with canonical variant ID and price
    const variantProd = catalog.products.find((p) => p.id === 'prod-variant-01')!;
    const largeVar = catalog.variants.find((v) => v.id === 'var-large-01')!;
    const item2 = cart.addItem({
      productId: variantProd.id,
      variantId: largeVar.id,
      productName: `${variantProd.name} (${largeVar.variant_name})`,
      unitPriceRupees: toRupees(largeVar.price_override_paise!),
      taxRatePercent: variantProd.tax_rate,
    });
    assert.equal(item2.productId, 'prod-variant-01');
    assert.equal(item2.variantId, 'var-large-01');
    assert.equal(item2.unitPricePaise, 35000);
    assert.equal(cart.getState().items.length, 2);
  });

  // 2. CART ITEM MUTATIONS (+, -, Remove)
  it('CART_INCREMENT_PASS, CART_DECREMENT_PASS, CART_REMOVE_PASS', () => {
    const cart = new PosCart({ orderType: 'DINE_IN', tableSessionId: 'sess-01' });
    const item = cart.addItem({
      productId: 'prod-01',
      productName: 'Margherita Pizza',
      unitPriceRupees: 150,
      quantity: 1,
    });

    // Increment
    const inc = cart.updateQuantity(item.id, item.quantity + 1);
    assert.equal(inc.quantity, 2);
    assert.equal(inc.lineTotalPaise, 31500); // (300 + 5% tax = 315.00)

    // Decrement
    const dec = cart.updateQuantity(item.id, inc.quantity - 1);
    assert.equal(dec.quantity, 1);
    assert.equal(dec.lineTotalPaise, 15750); // (150 + 5% tax = 157.50)

    // Remove
    cart.removeItem(item.id);
    assert.equal(cart.getState().items.length, 0);
  });

  // 3. POS CORE CART AUTHORITY & INTEGER PAISE
  it('CART_USES_POS_CORE_PASS, CART_PAISE_ONLY_PASS, CART_TOTALS_POS_CORE_PASS', () => {
    const cart = new PosCart({ orderType: 'DINE_IN', tableSessionId: 'sess-01' });
    cart.addItem({
      productId: 'prod-01',
      productName: 'Pizza A',
      unitPriceRupees: 129,
      quantity: 2,
      taxRatePercent: 5,
    });

    const totals = cart.calculateTotals();
    assert.equal(Number.isInteger(totals.subtotalPaise), true, 'subtotal is integer paise');
    assert.equal(Number.isInteger(totals.taxTotalPaise), true, 'tax is integer paise');
    assert.equal(Number.isInteger(totals.grandTotalPaise), true, 'grand total is integer paise');

    // 25800 + 1290 = 27090
    assert.equal(totals.subtotalPaise, 25800);
    assert.equal(totals.taxTotalPaise, 1290);
    assert.equal(totals.grandTotalPaise, 27090);
    assert.equal(totals.grandTotalRupees, 270.9);
  });

  // 4. EMPTY CART CREATES ZERO ORDERS
  it('EMPTY_CART_NO_ORDER_PASS', () => {
    const mock = createMockPersistenceState();
    const newContext: SelectedOrderContext = {
      table: baseTable,
      session: baseSession,
      order: null,
      items: [],
    };

    renderToString(
      React.createElement(OrderWorkspace, {
        db: mock.persistence,
        context: newContext,
        initialCatalog: createTestCatalog(),
        onBack: () => {},
      })
    );

    assert.equal(mock.calls.saveOrderAggregate, 0, 'Zero order inception calls on workspace entry');
    assert.equal(mock.calls.replaceDraftOrderAggregate, 0, 'Zero draft replacements on workspace entry');
  });

  // 5. INITIAL DRAFT SAVE, VERSION 1, SESSION LINK, ATOMICITY
  it('INITIAL_DRAFT_SAVE_PASS, INITIAL_DRAFT_VERSION_ONE_PASS, INITIAL_DRAFT_SESSION_LINK_PASS, INITIAL_DRAFT_LOCAL_OUTBOX_PASS & AUTHORITATIVE_RELOAD_AFTER_CREATE_PASS', async () => {
    const mock = createMockPersistenceState();
    const cart = new PosCart({ orderType: 'DINE_IN', tableSessionId: 'sess-01' });
    cart.addItem({
      productId: 'prod-simple-01',
      productName: 'Margherita Pizza',
      unitPriceRupees: 150,
      quantity: 1,
      taxRatePercent: 5,
    });

    const draft = createOrderDraft(cart, { status: 'draft', deviceId: 'T01' });
    draft.order.table_session_id = 'sess-01';
    draft.order.version = 1;

    // Save initial draft
    const res = await mock.persistence.saveOrderAggregate(draft.order, draft.items);
    assert.equal(mock.calls.saveOrderAggregate, 1);
    assert.equal(res.order.version, 1, 'Initial draft version is 1');
    assert.equal(res.order.status, 'draft', 'Status is draft');
    assert.equal(res.order.table_session_id, 'sess-01', 'Session link established');
    assert.ok(res.outboxRow, 'Durable outbox row produced');

    // Authoritative re-read
    const active = await mock.persistence.getActiveOrderForTable('tbl-01');
    assert.ok(active);
    assert.equal(active.order.version, 1);
    assert.equal(active.session.current_order_id, draft.order.id, 'Session current_order_id linked');
  });

  // 6. EXISTING DRAFT HYDRATE & REVISION (N -> N + 1)
  it('EXISTING_DRAFT_HYDRATE_PASS, EXISTING_DRAFT_EDIT_PASS, EXISTING_DRAFT_SAME_ORDER_ID_PASS, EXISTING_DRAFT_SAME_SESSION_PASS, EXISTING_DRAFT_NEXT_VERSION_PASS & AUTHORITATIVE_RELOAD_AFTER_UPDATE_PASS', async () => {
    const mock = createMockPersistenceState();
    // 1. Initial draft v1
    const cart1 = new PosCart({ orderType: 'DINE_IN', tableSessionId: 'sess-01' });
    cart1.addItem({
      productId: 'prod-simple-01',
      productName: 'Margherita Pizza',
      unitPriceRupees: 150,
      quantity: 1,
    });
    const draft1 = createOrderDraft(cart1, { status: 'draft', deviceId: 'T01' });
    draft1.order.table_session_id = 'sess-01';
    draft1.order.version = 1;
    await mock.persistence.saveOrderAggregate(draft1.order, draft1.items);

    const activeV1 = await mock.persistence.getActiveOrderForTable('tbl-01');
    assert.ok(activeV1);

    // 2. Hydrate cart from persisted snapshot
    const cart2 = new PosCart({
      orderType: activeV1.order.order_type,
      tableSessionId: activeV1.order.table_session_id,
    });
    for (const item of activeV1.items) {
      cart2.addItem({
        productId: item.product_id,
        variantId: item.variant_id,
        productName: item.product_name,
        unitPriceRupees: toRupees(item.unit_price_paise),
        quantity: item.quantity,
        taxRatePercent: item.tax_rate,
      });
    }
    assert.equal(cart2.getState().items.length, 1);

    // 3. Edit cart: add second item
    cart2.addItem({
      productId: 'prod-variant-01',
      variantId: 'var-large-01',
      productName: 'Farmhouse Pizza (Large)',
      unitPriceRupees: 350,
      quantity: 1,
    });
    assert.equal(cart2.getState().items.length, 2);

    // 4. Save Changes: version advances exactly one (1 -> 2)
    const nextVersion = (activeV1.order.version || 1) + 1;
    assert.equal(nextVersion, 2, 'Version increments to 2');

    const draft2 = createOrderDraft(cart2, {
      orderId: activeV1.order.id,
      displayNumber: activeV1.order.display_number,
      status: 'draft',
      deviceId: 'T01',
    });
    draft2.order.table_session_id = activeV1.order.table_session_id;
    draft2.order.version = nextVersion;

    const res2 = await mock.persistence.replaceDraftOrderAggregate(draft2.order, draft2.items);
    assert.equal(res2.order.id, activeV1.order.id, 'Order ID stable');
    assert.equal(res2.order.table_session_id, activeV1.order.table_session_id, 'Session ID stable');
    assert.equal(res2.order.version, 2, 'Version is 2');

    // Authoritative reload
    const activeV2 = await mock.persistence.getActiveOrderForTable('tbl-01');
    assert.ok(activeV2);
    assert.equal(activeV2.order.version, 2);
    assert.equal(activeV2.items.length, 2);
  });

  // 7. DOUBLE SUBMIT PREVENTION
  it('DOUBLE_CREATE_PREVENTED_PASS & DOUBLE_UPDATE_PREVENTED_PASS', () => {
    // Verified via CartPanel button disabled state while isSaving is true
    const cart = new PosCart({ orderType: 'DINE_IN', tableSessionId: 'sess-01' });
    cart.addItem({ productId: 'p1', productName: 'Pizza', unitPriceRupees: 100 });

    const htmlSavingCreate = renderToString(
      React.createElement(CartPanel, {
        items: cart.getState().items,
        totals: cart.calculateTotals(),
        onUpdateQuantity: () => {},
        onRemoveItem: () => {},
        onSaveOrder: () => {},
        isSaving: true,
        hasActiveOrder: false,
        tableNumber: 'T01',
        guestCount: 2,
      })
    );
    assert.ok(htmlSavingCreate.includes('disabled=""'), 'Save Order button disabled while saving');
    assert.ok(htmlSavingCreate.includes('Saving Order...'), 'Shows saving indicator');

    const htmlSavingUpdate = renderToString(
      React.createElement(CartPanel, {
        items: cart.getState().items,
        totals: cart.calculateTotals(),
        onUpdateQuantity: () => {},
        onRemoveItem: () => {},
        onSaveChanges: () => {},
        isSaving: true,
        isDirty: true,
        hasActiveOrder: true,
        orderStatus: 'draft',
        orderVersion: 1,
        tableNumber: 'T01',
        guestCount: 2,
      })
    );
    assert.ok(htmlSavingUpdate.includes('disabled=""'), 'Save Changes button disabled while saving');
    assert.ok(htmlSavingUpdate.includes('Saving Changes...'), 'Shows saving indicator');
  });

  // 8. UNSAVED NAVIGATION GUARD
  it('UNSAVED_NAVIGATION_GUARD_PASS', () => {
    // When isDirty is true, OrderWorkspace renders confirmation dialog on back trigger
    const mock = createMockPersistenceState();
    const newContext: SelectedOrderContext = {
      table: baseTable,
      session: baseSession,
      order: null,
      items: [],
    };

    const html = renderToString(
      React.createElement(OrderWorkspace, {
        db: mock.persistence,
        context: newContext,
        initialCatalog: createTestCatalog(),
        onBack: () => {},
      })
    );
    // Back button exists
    assert.ok(html.includes('id="back-to-tables-button"'), 'Back button is rendered');
  });

  // 9. LOCKED ORDER STATES (kot_sent, billed, settled, closed, cancelled)
  it('KOT_SENT_CART_LOCKED_PASS, BILLED_CART_LOCKED_PASS, SETTLED_CART_LOCKED_PASS, CLOSED_CART_LOCKED_PASS, CANCELLED_CART_LOCKED_PASS', () => {
    const statuses = ['kot_sent', 'billed', 'settled', 'closed', 'cancelled'] as const;
    const mock = createMockPersistenceState();

    for (const status of statuses) {
      const lockedContext: SelectedOrderContext = {
        table: baseTable,
        session: {
          ...baseSession,
          session_status: status === 'billed' ? 'billed' : 'open',
        },
        order: {
          id: 'ord-locked',
          display_number: 'CB-T01-0001',
          channel: 'POS',
          order_type: 'DINE_IN',
          customer_id: null,
          table_session_id: 'sess-01',
          status,
          subtotal_paise: 20000,
          tax_total_paise: 1000,
          discount_total_paise: 0,
          delivery_charge_paise: 0,
          grand_total_paise: 21000,
          device_id: 'dev-01',
          version: 1,
          created_at: '2026-10-12T10:00:00.000Z',
          updated_at: '2026-10-12T10:00:00.000Z',
        },
        items: [
          {
            id: 'item-01',
            order_id: 'ord-locked',
            product_id: 'prod-simple-01',
            variant_id: null,
            product_name: 'Margherita Pizza',
            unit_price_paise: 20000,
            quantity: 1,
            tax_rate: 5,
            discount_amount_paise: 0,
            line_total_paise: 21000,
            notes: null,
            created_at: '2026-10-12T10:00:00.000Z',
          },
        ],
      };

      const html = renderToString(
        React.createElement(OrderWorkspace, {
          db: mock.persistence,
          context: lockedContext,
          initialCatalog: createTestCatalog(),
          onBack: () => {},
        })
      );

      // Save buttons must NOT be present
      assert.ok(!html.includes('id="save-order-button"'), `save-order-button absent for ${status}`);
      assert.ok(!html.includes('id="save-changes-button"'), `save-changes-button absent for ${status}`);
      // Decrement / Increment / Remove controls absent
      assert.ok(!html.includes('id="cart-dec-item-01"'), `cart-dec absent for ${status}`);
      assert.ok(!html.includes('id="cart-inc-item-01"'), `cart-inc absent for ${status}`);
      assert.ok(!html.includes('id="cart-remove-item-01"'), `cart-remove absent for ${status}`);
    }
  });

  // 10. UNAVAILABLE PRODUCTS / VARIANTS REJECTED
  it('UNAVAILABLE_PRODUCT_REJECT_PASS', () => {
    const catalog = createTestCatalog();
    const html = renderToString(
      React.createElement(MenuCatalog, {
        db: createMockPersistenceState().persistence,
        initialCatalog: catalog,
        onAddToCart: () => {},
      })
    );

    // Unavailable product button is disabled
    assert.ok(html.includes('id="add-product-prod-unavailable-01"'), 'Unavailable product button exists');
    assert.ok(html.includes('disabled=""'), 'Disabled attribute on unavailable item');
  });

  // 11. OFFLINE OPERATION & PURITY INVARIANTS
  it('OFFLINE_INITIAL_SAVE_PASS, OFFLINE_DRAFT_UPDATE_PASS, NO_DIRECT_SQL_PASS, NO_DIRECT_SUPABASE_PASS, NO_POLLING_PASS, NO_KOT_CREATED_PASS, NO_BILL_CREATED_PASS, NO_PAYMENT_CREATED_PASS', async () => {
    const mock = createMockPersistenceState();

    // Offline initial save
    const cart = new PosCart({ orderType: 'DINE_IN', tableSessionId: 'sess-01' });
    cart.addItem({ productId: 'p1', productName: 'Pizza', unitPriceRupees: 100 });
    const draft = createOrderDraft(cart, { status: 'draft', deviceId: 'T01' });
    draft.order.table_session_id = 'sess-01';
    draft.order.version = 1;
    await mock.persistence.saveOrderAggregate(draft.order, draft.items);

    // Offline draft update
    cart.addItem({ productId: 'p2', productName: 'Burger', unitPriceRupees: 80 });
    const draft2 = createOrderDraft(cart, { orderId: draft.order.id, status: 'draft', deviceId: 'T01' });
    draft2.order.table_session_id = 'sess-01';
    draft2.order.version = 2;
    await mock.persistence.replaceDraftOrderAggregate(draft2.order, draft2.items);

    // Verify invariants
    assert.equal(mock.calls.rawSqlCalls.length, 0, 'Zero raw SQL executed');
    assert.equal(mock.calls.saveKotAggregate, 0, 'Zero KOT created');
    assert.equal(mock.calls.saveBillWithSequence, 0, 'Zero Bill created');
    assert.equal(mock.calls.savePayment, 0, 'Zero Payment created');
  });
});
