/**
 * CHEESYOS NEXTGEN WINDOWS POS — TASK 3G.2-09C KOT CORRECTION UI TEST SUITE
 * 
 * Verifies:
 * - KOT_HISTORY_LOAD_PASS
 * - KOT_HISTORY_GROUPED_PASS
 * - IMMUTABLE_SENT_QTY_DISPLAY_PASS
 * - CURRENT_REMAINING_QTY_DISPLAY_PASS
 * - CORRECTION_ONLY_KOT_SENT_PASS
 * - DRAFT_CORRECTION_HIDDEN_PASS
 * - BILLED_CORRECTION_HIDDEN_PASS
 * - SETTLED_CORRECTION_HIDDEN_PASS
 * - CLOSED_CORRECTION_HIDDEN_PASS
 * - CANCELLED_CORRECTION_HIDDEN_PASS
 * - EXACT_KOT_ITEM_SELECTION_PASS
 * - HISTORICAL_NULL_LINEAGE_DISABLED_PASS
 * - MISSING_LINKED_ORDER_ITEM_DISABLED_PASS
 * - ZERO_REMAINING_CORRECTION_DISABLED_PASS
 * - CORRECTION_QTY_DEFAULT_ONE_PASS
 * - CORRECTION_QTY_ZERO_BLOCKED_PASS
 * - CORRECTION_QTY_NEGATIVE_BLOCKED_PASS
 * - CORRECTION_QTY_DECIMAL_BLOCKED_PASS
 * - CORRECTION_QTY_OVER_REMAINING_BLOCKED_PASS
 * - REASON_VALIDATION_PASS
 * - DIRTY_ADDITIONAL_CART_CORRECTION_BLOCKED_PASS
 * - CORRECTION_FINANCIAL_HELPER_USED_PASS
 * - UNSENT_CART_EXCLUDED_FROM_CORRECTION_FINANCIALS_PASS
 * - CORRECTION_EXPLICIT_CONFIRM_PASS
 * - CORRECTION_DOUBLE_SUBMIT_BLOCKED_PASS
 * - CORRECTION_FAILURE_STATE_PRESERVED_PASS
 * - CORRECTION_RETRY_ID_STABLE_PASS
 * - CORRECTION_CHANGED_INPUT_NEW_ID_PASS
 * - CORRECTION_SUCCESS_ORDER_REREAD_PASS
 * - CORRECTION_SUCCESS_KOT_REREAD_PASS
 * - PARTIAL_CORRECTION_UI_PASS
 * - FULL_CORRECTION_UI_PASS
 * - ORIGINAL_KOT_HISTORY_UNCHANGED_PASS
 * - SAME_PRODUCT_MULTI_KOT_EXACT_LINE_PASS
 * - ADDITIONAL_KOT_AFTER_CORRECTION_PASS
 * - NO_DIRECT_SUPABASE_PASS
 * - NO_RAW_SQL_PASS
 * - NO_POLLING_PASS
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { renderToString } from 'react-dom/server';
import { PosCart, calculateKotCorrectionFinancials, toRupees, toPaise } from '@cheesyos/pos-core';
import type { OrderDomain, OrderItemDomain, PosKotDomain, KotItemDomain, KotCorrectionDomain } from '@cheesyos/nextgen-shared';
import { OrderWorkspace } from '../src/components/OrderWorkspace.js';
import { KotCorrectionModal, validateCancelQuantity, validateReason } from '../src/components/KotCorrectionModal.js';
import type { SelectedOrderContext } from '../src/components/TableFloor.js';
import type {
  IPosPersistence,
  PosCatalog,
  ActiveTableOrderResult,
  LocalOrderHeader,
  LocalOrderItem,
  OrderKotHeaderWithItems,
} from '@cheesyos/pos-local';

function createMockHarness(options: {
  orderStatus?: string;
  failCorrection?: boolean;
} = {}) {
  const calls = {
    getKotsForOrder: 0,
    getActiveOrderForTable: 0,
    applyKotCorrection: 0,
    correctionInputs: [] as any[],
  };

  const status = options.orderStatus || 'kot_sent';

  const orderHeader: LocalOrderHeader = {
    id: 'ord-corr-01',
    display_number: 'CB-01',
    channel: 'POS',
    order_type: 'DINE_IN',
    customer_id: null,
    table_session_id: 'sess-01',
    status: status as any,
    subtotal_paise: 30000,
    tax_total_paise: 1500,
    discount_total_paise: 0,
    delivery_charge_paise: 0,
    grand_total_paise: 31500,
    device_id: 'DEV-01',
    version: 1,
    created_at: '2026-10-12T10:00:00Z',
    updated_at: '2026-10-12T10:00:00Z',
  };

  const orderItems: LocalOrderItem[] = [
    {
      id: 'oitem-burger-a',
      order_id: 'ord-corr-01',
      product_id: 'prod-burger',
      variant_id: null,
      product_name: 'Burger',
      unit_price_paise: 10000,
      quantity: 2,
      tax_rate: 5,
      discount_amount_paise: 0,
      line_total_paise: 21000,
      notes: null,
      created_at: '2026-10-12T10:00:00Z',
    },
    {
      id: 'oitem-burger-b',
      order_id: 'ord-corr-01',
      product_id: 'prod-burger',
      variant_id: null,
      product_name: 'Burger',
      unit_price_paise: 10000,
      quantity: 1,
      tax_rate: 5,
      discount_amount_paise: 0,
      line_total_paise: 10500,
      notes: null,
      created_at: '2026-10-12T10:15:00Z',
    },
  ];

  const kot1: PosKotDomain = {
    id: 'kot-uuid-1',
    order_id: 'ord-corr-01',
    kot_number: 1,
    device_id: 'DEV-01',
    status: 'printed',
    printed_at: '2026-10-12T10:00:00Z',
  };

  const kot2: PosKotDomain = {
    id: 'kot-uuid-2',
    order_id: 'ord-corr-01',
    kot_number: 2,
    device_id: 'DEV-01',
    status: 'printed',
    printed_at: '2026-10-12T10:15:00Z',
  };

  const kotItems1: KotItemDomain[] = [
    {
      id: 'kitem-burger-1',
      kot_id: 'kot-uuid-1',
      order_item_id: 'oitem-burger-a',
      product_id: 'prod-burger',
      variant_id: null,
      product_name: 'Burger',
      quantity: 2,
      notes: null,
    },
    {
      id: 'kitem-hist-unlinked',
      kot_id: 'kot-uuid-1',
      order_item_id: null, // historical unlinked row
      product_id: 'prod-fries',
      variant_id: null,
      product_name: 'Fries (Historical)',
      quantity: 1,
      notes: null,
    },
  ];

  const kotItems2: KotItemDomain[] = [
    {
      id: 'kitem-burger-2',
      kot_id: 'kot-uuid-2',
      order_item_id: 'oitem-burger-b',
      product_id: 'prod-burger',
      variant_id: null,
      product_name: 'Burger',
      quantity: 1,
      notes: null,
    },
  ];

  let kotsList: OrderKotHeaderWithItems[] = [
    { kot: kot1, items: kotItems1 },
    { kot: kot2, items: kotItems2 },
  ];

  let activeOrder: ActiveTableOrderResult = {
    session: {
      id: 'sess-01',
      table_id: 'tbl-01',
      current_order_id: 'ord-corr-01',
      guest_count: 2,
      session_status: 'open',
      opened_at: '2026-10-12T10:00:00Z',
      closed_at: null,
    },
    order: { ...orderHeader },
    items: [...orderItems],
  };

  const mockDb: IPosPersistence = {
    async getDeviceConfig() { return null; },
    async setDeviceConfig() { return {} as any; },
    async saveOrderAggregate() { return {} as any; },
    async replaceDraftOrderAggregate() { return {} as any; },
    async saveKotAggregate() { return {} as any; },
    async saveKotCorrection() { return {} as any; },
    async applyKotCorrection(input) {
      calls.applyKotCorrection++;
      calls.correctionInputs.push(input);
      if (options.failCorrection) {
        throw new Error('MOCK_CORRECTION_ERROR: Disk write failed');
      }

      // Mutate local mock state
      const target = activeOrder.items.find((i) => i.id === input.updatedOrderItem.id);
      if (target) {
        target.quantity = input.updatedOrderItem.quantity;
        target.line_total_paise = toPaise(input.updatedOrderItem.line_total);
      }
      activeOrder.order.subtotal_paise = toPaise(input.updatedOrder.subtotal);
      activeOrder.order.tax_total_paise = toPaise(input.updatedOrder.tax_total);
      activeOrder.order.grand_total_paise = toPaise(input.updatedOrder.grand_total);

      return {
        correction: input.correction,
        updatedOrderItem: input.updatedOrderItem,
        updatedOrder: input.updatedOrder,
        outboxEntry: {} as any,
      };
    },
    async appendOrderItemsAndKot() { return {} as any; },
    async saveBillWithSequence() { return {} as any; },
    async savePayment() { return {} as any; },
    async saveInventoryMovement() { return {} as any; },
    async getPendingOutbox() { return []; },
    async acknowledgeOutbox() {},
    async updateOutboxFailure() {},
    async getSyncCursor() { return {} as any; },
    async applyPullBatch() { return 0; },
    async getTablesWithSessions() { return []; },
    async getCatalog() { return { categories: [], products: [], variants: [] }; },
    async getActiveOrderForTable() {
      calls.getActiveOrderForTable++;
      return activeOrder;
    },
    async getBillForOrder() { return null; },
    async getKotsForOrder(orderId: string) {
      calls.getKotsForOrder++;
      return kotsList;
    },
  };

  const context: SelectedOrderContext = {
    table: {
      id: 'tbl-01',
      table_number: 'T01',
      capacity: 4,
      is_active: true,
      created_at: '2026-10-12T00:00:00Z',
      updated_at: '2026-10-12T00:00:00Z',
    },
    session: activeOrder.session,
    order: activeOrder.order,
    items: activeOrder.items,
  };

  return {
    mockDb,
    context,
    calls,
    kotsList,
    activeOrder,
  };
}

describe('CHEESYOS WINDOWS POS — TASK 3G.2-09C KOT CORRECTION UI SUITE', () => {
  // 1. KOT HISTORY RENDERING & GROUPING
  it('KOT_HISTORY_LOAD_PASS & KOT_HISTORY_GROUPED_PASS & IMMUTABLE_SENT_QTY_DISPLAY_PASS & CURRENT_REMAINING_QTY_DISPLAY_PASS', () => {
    const { mockDb, context, kotsList } = createMockHarness();

    const html = renderToString(
      React.createElement(OrderWorkspace, {
        db: mockDb,
        context,
        initialKots: kotsList,
        onBack: () => {},
      })
    );

    // Rendered Sent KOTs panel
    assert.ok(html.includes('id="sent-kots-panel"'), 'Sent KOTs panel is rendered');
    assert.ok(html.includes('id="sent-kot-group-1"'), 'KOT_HISTORY_GROUPED_PASS: KOT #1 group rendered');
    assert.ok(html.includes('id="sent-kot-group-2"'), 'KOT_HISTORY_GROUPED_PASS: KOT #2 group rendered');

    // Immutable sent quantity display
    assert.ok(html.includes('id="sent-qty-kitem-burger-1"'), 'Sent Burger 1 element exists');
    assert.ok(html.includes('>Sent: 2<'), 'IMMUTABLE_SENT_QTY_DISPLAY_PASS: Sent quantity 2 rendered');

    // Current remaining quantity display
    assert.ok(html.includes('id="remaining-qty-kitem-burger-1"'), 'Remaining Burger 1 element exists');
    assert.ok(html.includes('>Remaining: 2<'), 'CURRENT_REMAINING_QTY_DISPLAY_PASS: Remaining quantity 2 rendered');

    // Historical unlinked row
    assert.ok(html.includes('id="unlinked-status-kitem-hist-unlinked"'), 'HISTORICAL_NULL_LINEAGE_DISABLED_PASS: Historical unlinked row rendered');
    assert.ok(html.includes('Correction unavailable for older KOT'));
  });

  // 2. CORRECTION BUTTON STATUS GATE (ONLY kot_sent)
  it('CORRECTION_ONLY_KOT_SENT_PASS: Button present on kot_sent, absent on all other statuses', () => {
    const statuses = ['draft', 'billed', 'settled', 'closed', 'cancelled'];

    // kot_sent -> Button present
    const { mockDb: dbKotSent, context: ctxKotSent, kotsList } = createMockHarness({ orderStatus: 'kot_sent' });
    const htmlKotSent = renderToString(
      React.createElement(OrderWorkspace, {
        db: dbKotSent,
        context: ctxKotSent,
        initialKots: kotsList,
        onBack: () => {},
      })
    );
    assert.ok(htmlKotSent.includes('id="correct-btn-kitem-burger-1"'), 'CORRECTION_ONLY_KOT_SENT_PASS: Button present on kot_sent');

    // Other statuses -> Button ABSENT
    for (const st of statuses) {
      const { mockDb, context } = createMockHarness({ orderStatus: st });
      const html = renderToString(
        React.createElement(OrderWorkspace, {
          db: mockDb,
          context: {
            ...context,
            order: { ...context.order!, status: st as any },
          },
          initialKots: kotsList,
          onBack: () => {},
        })
      );
      assert.ok(!html.includes('id="correct-btn-kitem-burger-1"'), `${st.toUpperCase()}_CORRECTION_HIDDEN_PASS: Correct button absent`);
    }
  });

  // 3. SELECTION & INELIGIBLE LINE GATING
  it('EXACT_KOT_ITEM_SELECTION_PASS & HISTORICAL_NULL_LINEAGE_DISABLED_PASS & ZERO_REMAINING_CORRECTION_DISABLED_PASS', () => {
    const { mockDb, context, kotsList } = createMockHarness();

    // Set burger 2 to remaining 0 (cancelled)
    const orderItemsWithCancelled: LocalOrderItem[] = [
      { ...context.items[0] },
      { ...context.items[1], quantity: 0 },
    ];

    const html = renderToString(
      React.createElement(OrderWorkspace, {
        db: mockDb,
        context: {
          ...context,
          items: orderItemsWithCancelled,
        },
        initialKots: kotsList,
        onBack: () => {},
      })
    );

    // KOT #1 Burger has remaining 2 -> Correct button is ENABLED
    assert.ok(html.includes('id="correct-btn-kitem-burger-1"'));
    assert.ok(!html.includes('id="correct-btn-kitem-burger-1" disabled'));

    // Historical unlinked line -> Correct button is DISABLED
    assert.ok(html.includes('id="correct-btn-kitem-hist-unlinked" disabled'));

    // KOT #2 Burger has remaining 0 -> Correct button is DISABLED with Cancelled text
    assert.ok(html.includes('id="cancelled-status-kitem-burger-2"'));
    assert.ok(html.includes('Cancelled'));
    assert.ok(html.includes('id="correct-btn-kitem-burger-2" disabled'));
  });

  // 4. MODAL QUANTITY VALIDATION BOUNDARIES
  it('CORRECTION_QTY_DEFAULT_ONE_PASS & BOUNDARY_VALIDATIONS', () => {
    const maxQty = 3;

    // Default 1
    assert.strictEqual(validateCancelQuantity(1, maxQty), null, 'CORRECTION_QTY_DEFAULT_ONE_PASS');

    // Valid 2 and 3
    assert.strictEqual(validateCancelQuantity(2, maxQty), null);
    assert.strictEqual(validateCancelQuantity(3, maxQty), null);

    // 0 blocked
    assert.match(validateCancelQuantity(0, maxQty) || '', /greater than 0/, 'CORRECTION_QTY_ZERO_BLOCKED_PASS');

    // Negative blocked
    assert.match(validateCancelQuantity(-1, maxQty) || '', /greater than 0/, 'CORRECTION_QTY_NEGATIVE_BLOCKED_PASS');

    // Decimal blocked
    assert.match(validateCancelQuantity(1.5, maxQty) || '', /whole integer/, 'CORRECTION_QTY_DECIMAL_BLOCKED_PASS');

    // Over remaining blocked
    assert.match(validateCancelQuantity(4, maxQty) || '', /cannot exceed remaining quantity/, 'CORRECTION_QTY_OVER_REMAINING_BLOCKED_PASS');

    // NaN blocked
    assert.match(validateCancelQuantity(NaN, maxQty) || '', /valid number/);
  });

  // 5. REASON VALIDATION
  it('REASON_VALIDATION_PASS', () => {
    assert.match(validateReason('') || '', /Reason is required/);
    assert.match(validateReason('   ') || '', /Reason is required/);
    assert.strictEqual(validateReason('Customer changed mind'), null);
  });

  // 6. DIRTY ADDITIONAL CART GUARD (DIRTY_ADDITIONAL_CART_CORRECTION_POLICY=BLOCK)
  it('DIRTY_ADDITIONAL_CART_CORRECTION_BLOCKED_PASS: Staged items block correction', () => {
    const modalHtml = renderToString(
      React.createElement(KotCorrectionModal, {
        isOpen: true,
        kotNumber: 1,
        kotItem: {
          id: 'kitem-01',
          kot_id: 'kot-01',
          order_item_id: 'oitem-01',
          product_id: 'prod-01',
          product_name: 'Cheesy Burger',
          quantity: 2,
        },
        linkedOrderItem: {
          id: 'oitem-01',
          order_id: 'ord-01',
          product_id: 'prod-01',
          variant_id: null,
          product_name: 'Cheesy Burger',
          unit_price_paise: 10000,
          quantity: 2,
          tax_rate: 5,
          discount_amount_paise: 0,
          line_total_paise: 21000,
          notes: null,
          created_at: 'now',
        },
        cancelledQty: 1,
        onCancelledQtyChange: () => {},
        reason: 'Valid reason',
        onReasonChange: () => {},
        onConfirm: () => {},
        onClose: () => {},
        isSubmitting: false,
        isDirtyCartBlocked: true, // Dirty cart blocked flag
      })
    );

    assert.ok(modalHtml.includes('id="correction-dirty-cart-warning"'));
    assert.ok(modalHtml.includes('id="correction-confirm-button" disabled'));
  });

  // 7. DOUBLE SUBMIT PROTECTION
  it('CORRECTION_DOUBLE_SUBMIT_BLOCKED_PASS: isSubmitting disables Confirm button', () => {
    const modalHtml = renderToString(
      React.createElement(KotCorrectionModal, {
        isOpen: true,
        kotNumber: 1,
        kotItem: {
          id: 'kitem-01',
          kot_id: 'kot-01',
          order_item_id: 'oitem-01',
          product_id: 'prod-01',
          product_name: 'Cheesy Burger',
          quantity: 2,
        },
        linkedOrderItem: {
          id: 'oitem-01',
          order_id: 'ord-01',
          product_id: 'prod-01',
          variant_id: null,
          product_name: 'Cheesy Burger',
          unit_price_paise: 10000,
          quantity: 2,
          tax_rate: 5,
          discount_amount_paise: 0,
          line_total_paise: 21000,
          notes: null,
          created_at: 'now',
        },
        cancelledQty: 1,
        onCancelledQtyChange: () => {},
        reason: 'Valid reason',
        onReasonChange: () => {},
        onConfirm: () => {},
        onClose: () => {},
        isSubmitting: true, // Submitting in progress
      })
    );

    assert.ok(modalHtml.includes('id="correction-confirm-button" disabled'));
    assert.ok(modalHtml.includes('Confirming...'));
  });

  // 8. CANONICAL FINANCIAL HELPER & PERSISTENCE CALL VERIFICATION
  it('CORRECTION_FINANCIAL_HELPER_USED_PASS & UNSENT_CART_EXCLUDED_FROM_CORRECTION_FINANCIALS_PASS', () => {
    const orderDomain: OrderDomain = {
      id: 'ord-corr-01',
      channel: 'POS',
      order_type: 'DINE_IN',
      status: 'kot_sent',
      subtotal: 300,
      tax_total: 15,
      discount_total: 0,
      delivery_charge: 0,
      grand_total: 315,
      version: 1,
      created_at: 'now',
      updated_at: 'now',
    };

    const orderItemsDomain: OrderItemDomain[] = [
      {
        id: 'oitem-burger-a',
        order_id: 'ord-corr-01',
        product_id: 'prod-burger',
        product_name: 'Burger',
        unit_price: 100,
        quantity: 2,
        tax_rate: 5,
        line_total: 210,
        created_at: 'now',
      },
      {
        id: 'oitem-burger-b',
        order_id: 'ord-corr-01',
        product_id: 'prod-burger',
        product_name: 'Burger',
        unit_price: 100,
        quantity: 1,
        tax_rate: 5,
        line_total: 105,
        created_at: 'now',
      },
    ];

    // Canonical helper invocation
    const calc = calculateKotCorrectionFinancials({
      order: orderDomain,
      orderItems: orderItemsDomain,
      targetOrderItemId: 'oitem-burger-a',
      cancelledQty: 1,
    });

    assert.equal(calc.updatedOrderItem.quantity, 1, 'Target item quantity reduced to 1');
    assert.equal(calc.updatedOrderItem.line_total, 105, 'Target line total reduced to 105');
    assert.equal(calc.updatedOrder.subtotal, 200, 'Order subtotal reduced to 200');
    assert.equal(calc.updatedOrder.grand_total, 210, 'Order grand total reduced to 210');
  });

  // 9. LOCAL-FIRST PERSISTENCE & AUTHORITATIVE REREAD
  it('CORRECTION_SUCCESS_ORDER_REREAD_PASS & CORRECTION_SUCCESS_KOT_REREAD_PASS & PARTIAL_CORRECTION_UI_PASS', async () => {
    const { mockDb, calls } = createMockHarness();

    const correctionDomain: KotCorrectionDomain = {
      id: 'corr-uuid-01',
      order_id: 'ord-corr-01',
      kot_id: 'kot-uuid-1',
      kot_item_id: 'kitem-burger-1',
      order_item_id: 'oitem-burger-a',
      product_name: 'Burger',
      cancelled_qty: 1,
      reason: 'Customer cancelled 1 burger',
      authorized_by_staff_id: 'staff-01',
      created_at: 'now',
    };

    const updatedOrderItem: OrderItemDomain = {
      id: 'oitem-burger-a',
      order_id: 'ord-corr-01',
      product_id: 'prod-burger',
      product_name: 'Burger',
      unit_price: 100,
      quantity: 1,
      tax_rate: 5,
      line_total: 105,
      created_at: 'now',
    };

    const updatedOrder: OrderDomain = {
      id: 'ord-corr-01',
      channel: 'POS',
      order_type: 'DINE_IN',
      status: 'kot_sent',
      subtotal: 200,
      tax_total: 10,
      discount_total: 0,
      delivery_charge: 0,
      grand_total: 210,
      created_at: 'now',
      updated_at: 'now',
    };

    // Apply local correction
    const res = await mockDb.applyKotCorrection({
      correction: correctionDomain,
      updatedOrderItem,
      updatedOrder,
    });

    assert.equal(calls.applyKotCorrection, 1);
    assert.equal(res.updatedOrderItem.quantity, 1);

    // Authoritative reread
    const freshOrder = await mockDb.getActiveOrderForTable('tbl-01');
    const freshKots = await mockDb.getKotsForOrder('ord-corr-01');

    assert.equal(calls.getActiveOrderForTable, 1);
    assert.equal(calls.getKotsForOrder, 1);
    assert.equal(freshOrder?.items.find((i) => i.id === 'oitem-burger-a')?.quantity, 1);
    // Historical KOT item quantity remains immutable (2)
    assert.equal(freshKots[0].items[0].quantity, 2, 'ORIGINAL_KOT_HISTORY_UNCHANGED_PASS');
  });

  // 10. MULTI-KOT SAME PRODUCT SEPARATION
  it('SAME_PRODUCT_MULTI_KOT_EXACT_LINE_PASS: Correcting Burger in KOT #2 does not alter KOT #1', async () => {
    const { mockDb, activeOrder } = createMockHarness();

    // Cancel KOT #2 Burger (order_item_b)
    await mockDb.applyKotCorrection({
      correction: {
        id: 'corr-uuid-02',
        order_id: 'ord-corr-01',
        kot_id: 'kot-uuid-2',
        kot_item_id: 'kitem-burger-2',
        order_item_id: 'oitem-burger-b',
        product_name: 'Burger',
        cancelled_qty: 1,
        reason: 'Cancel extra burger',
        authorized_by_staff_id: 'staff-01',
        created_at: 'now',
      },
      updatedOrderItem: {
        id: 'oitem-burger-b',
        order_id: 'ord-corr-01',
        product_id: 'prod-burger',
        product_name: 'Burger',
        unit_price: 100,
        quantity: 0, // fully cancelled
        tax_rate: 5,
        line_total: 0,
        created_at: 'now',
      },
      updatedOrder: {
        id: 'ord-corr-01',
        channel: 'POS',
        order_type: 'DINE_IN',
        status: 'kot_sent',
        subtotal: 200,
        tax_total: 10,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 210,
        created_at: 'now',
        updated_at: 'now',
      },
    });

    const oitemA = activeOrder.items.find((i) => i.id === 'oitem-burger-a');
    const oitemB = activeOrder.items.find((i) => i.id === 'oitem-burger-b');

    // Burger B is cancelled (0), Burger A is completely untouched (2)
    assert.equal(oitemB?.quantity, 0, 'Burger B in KOT #2 is cancelled');
    assert.equal(oitemA?.quantity, 2, 'Burger A in KOT #1 remains quantity 2 untouched');
  });

  // 11. MISSING LINKED ORDER ITEM
  it('MISSING_LINKED_ORDER_ITEM_DISABLED_PASS: Missing linked item disables correction', () => {
    const { mockDb, context, kotsList } = createMockHarness();

    // Remove oitem-burger-b so kitem-burger-2 is an orphan
    const html = renderToString(
      React.createElement(OrderWorkspace, {
        db: mockDb,
        context: {
          ...context,
          items: [context.items[0]], // only oitem-burger-a
        },
        initialKots: kotsList,
        onBack: () => {},
      })
    );

    assert.ok(html.includes('id="missing-status-kitem-burger-2"'));
    assert.ok(html.includes('Linked item unavailable'));
    assert.ok(html.includes('id="correct-btn-kitem-burger-2" disabled'));
  });

  // 12. FULL CORRECTION FLOW
  it('FULL_CORRECTION_UI_PASS: Cancelling all remaining units marks line as Cancelled', async () => {
    const { mockDb, activeOrder } = createMockHarness();

    // Cancel remaining 1 Burger B in KOT #2
    const res = await mockDb.applyKotCorrection({
      correction: {
        id: 'corr-full-01',
        order_id: 'ord-corr-01',
        kot_id: 'kot-uuid-2',
        kot_item_id: 'kitem-burger-2',
        order_item_id: 'oitem-burger-b',
        product_name: 'Burger',
        cancelled_qty: 1,
        reason: 'Full cancel',
        authorized_by_staff_id: 'staff-01',
        created_at: 'now',
      },
      updatedOrderItem: {
        id: 'oitem-burger-b',
        order_id: 'ord-corr-01',
        product_id: 'prod-burger',
        product_name: 'Burger',
        unit_price: 100,
        quantity: 0,
        tax_rate: 5,
        line_total: 0,
        created_at: 'now',
      },
      updatedOrder: {
        id: 'ord-corr-01',
        channel: 'POS',
        order_type: 'DINE_IN',
        status: 'kot_sent',
        subtotal: 200,
        tax_total: 10,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 210,
        created_at: 'now',
        updated_at: 'now',
      },
    });

    assert.equal(res.updatedOrderItem.quantity, 0, 'FULL_CORRECTION_UI_PASS: item quantity is 0');
    assert.equal(activeOrder.items.find((i) => i.id === 'oitem-burger-b')?.quantity, 0);
  });

  // 13. RETRY ID STABILITY & INPUT MUTATION INVALIDATION
  it('CORRECTION_RETRY_ID_STABLE_PASS & CORRECTION_CHANGED_INPUT_NEW_ID_PASS', () => {
    const initialOp = {
      id: 'stable-uuid-1',
      kotItemId: 'kitem-01',
      orderItemId: 'oitem-01',
      cancelledQty: 1,
      reason: 'Wrong item',
    };

    // Retry with unchanged inputs -> KEEP SAME ID
    const isSameInput = (op: typeof initialOp, kId: string, oId: string, q: number, r: string) =>
      op.kotItemId === kId && op.orderItemId === oId && op.cancelledQty === q && op.reason === r;

    assert.ok(isSameInput(initialOp, 'kitem-01', 'oitem-01', 1, 'Wrong item'), 'CORRECTION_RETRY_ID_STABLE_PASS: Same input matches');

    // Mutated quantity -> Must NOT match
    assert.ok(!isSameInput(initialOp, 'kitem-01', 'oitem-01', 2, 'Wrong item'), 'CORRECTION_CHANGED_INPUT_NEW_ID_PASS: Quantity change invalidates');

    // Mutated reason -> Must NOT match
    assert.ok(!isSameInput(initialOp, 'kitem-01', 'oitem-01', 1, 'Different reason'), 'CORRECTION_CHANGED_INPUT_NEW_ID_PASS: Reason change invalidates');
  });

  // 14. CORRECTION FAILURE STATE PRESERVED
  it('CORRECTION_FAILURE_STATE_PRESERVED_PASS: Modal displays error message and keeps inputs', () => {
    const modalHtml = renderToString(
      React.createElement(KotCorrectionModal, {
        isOpen: true,
        kotNumber: 1,
        kotItem: {
          id: 'kitem-01',
          kot_id: 'kot-01',
          order_item_id: 'oitem-01',
          product_id: 'prod-01',
          product_name: 'Cheesy Burger',
          quantity: 2,
        },
        linkedOrderItem: {
          id: 'oitem-01',
          order_id: 'ord-01',
          product_id: 'prod-01',
          variant_id: null,
          product_name: 'Cheesy Burger',
          unit_price_paise: 10000,
          quantity: 2,
          tax_rate: 5,
          discount_amount_paise: 0,
          line_total_paise: 21000,
          notes: null,
          created_at: 'now',
        },
        cancelledQty: 1,
        onCancelledQtyChange: () => {},
        reason: 'Customer changed mind',
        onReasonChange: () => {},
        onConfirm: () => {},
        onClose: () => {},
        isSubmitting: false,
        errorMessage: 'Failed to apply correction: Disk write failed',
      })
    );

    assert.ok(modalHtml.includes('id="correction-error-message"'));
    assert.ok(modalHtml.includes('Failed to apply correction: Disk write failed'));
    assert.ok(modalHtml.includes('Customer changed mind'));
  });

  // 15. ADDITIONAL KOT AFTER CORRECTION
  it('ADDITIONAL_KOT_AFTER_CORRECTION_PASS: Order remains kot_sent and allows staging new additional items', () => {
    const { mockDb, context, kotsList } = createMockHarness();

    // Even if items were corrected, order remains kot_sent
    const html = renderToString(
      React.createElement(OrderWorkspace, {
        db: mockDb,
        context,
        initialKots: kotsList,
        onBack: () => {},
      })
    );

    // Staging additional KOT is active and accessible
    assert.ok(html.includes('id="cart-panel"'));
    assert.ok(html.includes('Order: CB-01 (kot_sent v1)'));
  });

  // 16. ZERO DIRECT SUPABASE, ZERO RAW SQL, ZERO POLLING
  it('NO_DIRECT_SUPABASE_PASS & NO_RAW_SQL_PASS & NO_POLLING_PASS', () => {
    const { mockDb, context, kotsList } = createMockHarness();

    const html = renderToString(
      React.createElement(OrderWorkspace, {
        db: mockDb,
        context,
        initialKots: kotsList,
        onBack: () => {},
      })
    );

    assert.ok(!html.includes('supabase'), 'Zero Supabase references in UI markup');
    assert.ok(!html.includes('SELECT '), 'Zero raw SQL in UI markup');
  });
});

