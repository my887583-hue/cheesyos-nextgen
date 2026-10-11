/**
 * CHEESYOS NEXTGEN POS CORE — ORDER DRAFT ENGINE
 * 
 * Creates deterministic order headers and item snapshots from validated cart states.
 */

import { OrderDomain, OrderItemDomain, OrderType, roundMoney } from '@cheesyos/nextgen-shared';
import { PosCart } from './cart.js';
import { toRupees } from './money.js';

export interface CreateOrderDraftOptions {
  orderId?: string; // Client-side generated UUID
  displayNumber?: string | null; // e.g. "CB-K01-000101"
  deviceId?: string | null;
  status?: 'draft' | 'pending' | 'kot_sent';
}

export interface OrderDraftResult {
  order: OrderDomain;
  items: OrderItemDomain[];
}

/**
 * Creates an immutable Order header and OrderItem snapshots from a PosCart instance.
 */
export function createOrderDraft(
  cart: PosCart,
  options?: CreateOrderDraftOptions
): OrderDraftResult {
  const cartState = cart.getState();

  if (!cartState.items || cartState.items.length === 0) {
    throw new Error('[OrderDraftEngine] Cannot create order draft from an empty cart');
  }

  const totals = cart.calculateTotals();
  const now = new Date().toISOString();
  const orderId = options?.orderId || crypto.randomUUID();

  const orderItems: OrderItemDomain[] = cartState.items.map((item) => {
    const itemId = crypto.randomUUID();
    return {
      id: itemId,
      order_id: orderId,
      product_id: item.productId,
      variant_id: item.variantId ?? null,
      product_name: item.productName,
      unit_price: roundMoney(toRupees(item.unitPricePaise)),
      quantity: item.quantity,
      tax_rate: item.taxRatePercent,
      discount_amount: roundMoney(toRupees(item.discountAmountPaise)),
      line_total: roundMoney(toRupees(item.lineTotalPaise)),
      notes: item.notes ?? null,
      created_at: now,
    };
  });

  const order: OrderDomain = {
    id: orderId,
    display_number: options?.displayNumber ?? null,
    channel: 'POS',
    order_type: cartState.orderType,
    customer_id: cartState.customerId ?? null,
    table_session_id: cartState.tableSessionId ?? null,
    status: options?.status || 'draft',
    subtotal: totals.subtotalRupees,
    tax_total: totals.taxTotalRupees,
    discount_total: totals.discountTotalRupees,
    delivery_charge: totals.deliveryChargeRupees,
    grand_total: totals.grandTotalRupees,
    device_id: options?.deviceId ?? null,
    created_at: now,
    updated_at: now,
  };

  return {
    order,
    items: orderItems,
  };
}
