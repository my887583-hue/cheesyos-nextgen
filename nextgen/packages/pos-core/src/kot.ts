/**
 * CHEESYOS NEXTGEN POS CORE — KOT DISPATCH & CORRECTION ENGINE
 * 
 * Creates immutable Kitchen Order Ticket (KOT) snapshots and authorization audit logs.
 */

import {
  PosKotDomain,
  KotItemDomain,
  KotCorrectionDomain,
  OrderItemDomain,
  OrderDomain,
  roundMoney,
} from '@cheesyos/nextgen-shared';
import { toPaise, toRupees, addPaise, mulPaise, percentagePaise } from './money.js';

export interface CreateKotSnapshotOptions {
  kotId?: string;
  kotNumber: number;
  deviceId?: string | null;
}

export interface KotDispatchResult {
  kot: PosKotDomain;
  items: KotItemDomain[];
}

export interface CreateKotCorrectionOptions {
  correctionId?: string;
  orderId: string;
  kotId?: string | null;
  kotItemId?: string | null;
  orderItemId?: string | null;
  productName: string;
  dispatchedQty?: number;
  currentQty?: number;
  cancelledQty: number;
  reason: string;
  authorizedByStaffId: string;
}

export interface CalculateKotCorrectionFinancialsInput {
  order: OrderDomain;
  orderItems: OrderItemDomain[];
  targetOrderItemId: string;
  cancelledQty: number;
}

export interface CorrectedOrderItemFinancials {
  id: string;
  quantity: number;
  line_total: number;
  line_total_paise: number;
}

export interface CorrectedOrderFinancials {
  id: string;
  subtotal: number;
  tax_total: number;
  discount_total: number;
  delivery_charge: number;
  grand_total: number;
  subtotal_paise: number;
  tax_total_paise: number;
  discount_total_paise: number;
  delivery_charge_paise: number;
  grand_total_paise: number;
}

export interface KotCorrectionFinancialsResult {
  updatedOrderItem: CorrectedOrderItemFinancials;
  updatedOrder: CorrectedOrderFinancials;
}

/**
 * Creates an immutable KOT header and KOT item snapshots for kitchen printing.
 * Populates canonical order_item_id lineage linking each kitchen line to its originating commercial line.
 */
export function createKotDispatchSnapshot(
  orderId: string,
  orderItems: OrderItemDomain[],
  options: CreateKotSnapshotOptions
): KotDispatchResult {
  if (!orderItems || orderItems.length === 0) {
    throw new Error('[KotEngine] Cannot create KOT snapshot for an order with no items');
  }

  if (options.kotNumber <= 0) {
    throw new Error('[KotEngine] KOT number must be a positive integer');
  }

  const kotId = options.kotId || crypto.randomUUID();
  const printedAt = new Date().toISOString();

  const kotItems: KotItemDomain[] = orderItems.map((item) => ({
    id: crypto.randomUUID(),
    kot_id: kotId,
    order_item_id: item.id,
    product_id: item.product_id,
    variant_id: item.variant_id ?? null,
    product_name: item.product_name,
    quantity: item.quantity,
    notes: item.notes ?? null,
  }));

  const kot: PosKotDomain = {
    id: kotId,
    order_id: orderId,
    kot_number: options.kotNumber,
    device_id: options.deviceId ?? null,
    status: 'printed',
    printed_at: printedAt,
  };

  return {
    kot,
    items: kotItems,
  };
}

/**
 * Creates an immutable KOT correction audit entry for item cancellations.
 * Validates cancellation bounds without mutating historical KOT snapshots.
 */
export function createKotCorrection(
  options: CreateKotCorrectionOptions
): KotCorrectionDomain {
  if (options.cancelledQty <= 0) {
    throw new Error('[KotEngine] Cancelled quantity must be greater than 0');
  }

  if (options.currentQty !== undefined && options.cancelledQty > options.currentQty) {
    throw new Error(
      `[KotEngine] Cannot cancel ${options.cancelledQty} units when only ${options.currentQty} are available`
    );
  } else if (options.dispatchedQty !== undefined && options.cancelledQty > options.dispatchedQty) {
    throw new Error(
      `[KotEngine] Cannot cancel ${options.cancelledQty} units when only ${options.dispatchedQty} were dispatched`
    );
  }

  if (!options.reason || options.reason.trim().length === 0) {
    throw new Error('[KotEngine] Reason is required for KOT correction');
  }

  if (!options.authorizedByStaffId) {
    throw new Error('[KotEngine] Staff ID is required to authorize KOT correction');
  }

  return {
    id: options.correctionId || crypto.randomUUID(),
    order_id: options.orderId,
    kot_id: options.kotId ?? null,
    kot_item_id: options.kotItemId ?? null,
    order_item_id: options.orderItemId ?? null,
    product_name: options.productName,
    cancelled_qty: options.cancelledQty,
    reason: options.reason.trim(),
    authorized_by_staff_id: options.authorizedByStaffId,
    created_at: new Date().toISOString(),
  };
}

/**
 * Pure, canonical financial recalculation engine for Model-B KOT item cancellations.
 * Calculates updated line totals, item discounts, and order cumulative totals using integer Paise primitives.
 * Safely preserves manual order-level discounts without double-deduction.
 */
export function calculateKotCorrectionFinancials(
  input: CalculateKotCorrectionFinancialsInput
): KotCorrectionFinancialsResult {
  const { order, orderItems, targetOrderItemId, cancelledQty } = input;

  if (cancelledQty <= 0) {
    throw new Error('[KotEngine] Cancelled quantity must be greater than 0');
  }

  const targetIndex = orderItems.findIndex((it) => it.id === targetOrderItemId);
  if (targetIndex < 0) {
    throw new Error(`[KotEngine] Target order item ${targetOrderItemId} not found in order items`);
  }

  const targetItem = orderItems[targetIndex];
  if (cancelledQty > targetItem.quantity) {
    throw new Error(
      `[KotEngine] Cannot cancel ${cancelledQty} units when current billable quantity is ${targetItem.quantity}`
    );
  }

  const newQty = targetItem.quantity - cancelledQty;

  // 1. Calculate new financials for the target item using integer Paise primitives
  const unitPricePaise = toPaise(targetItem.unit_price);
  const discountPerUnitPaise = toPaise(targetItem.discount_amount ?? 0);
  const newGrossPaise = mulPaise(unitPricePaise, newQty);
  const newItemDiscountPaise = mulPaise(discountPerUnitPaise, newQty);
  const newTaxablePaise = Math.max(0, newGrossPaise - newItemDiscountPaise);
  const newTaxPaise = percentagePaise(newTaxablePaise, targetItem.tax_rate);
  const newLineTotalPaise = addPaise(newTaxablePaise, newTaxPaise);

  // 2. Compute order cumulative totals across all items
  let subtotalPaise = 0;
  let itemsDiscountPaise = 0;
  let taxTotalPaise = 0;

  // Compute prior item discounts to preserve manual order discount safely
  let previousItemsDiscountPaise = 0;
  for (const it of orderItems) {
    previousItemsDiscountPaise = addPaise(
      previousItemsDiscountPaise,
      mulPaise(toPaise(it.discount_amount ?? 0), it.quantity)
    );
  }
  const orderDiscountTotalPaise = toPaise(order.discount_total ?? 0);
  const manualDiscountPaise = Math.max(0, orderDiscountTotalPaise - previousItemsDiscountPaise);

  for (let i = 0; i < orderItems.length; i++) {
    if (i === targetIndex) {
      subtotalPaise = addPaise(subtotalPaise, newTaxablePaise);
      itemsDiscountPaise = addPaise(itemsDiscountPaise, newItemDiscountPaise);
      taxTotalPaise = addPaise(taxTotalPaise, newTaxPaise);
    } else {
      const it = orderItems[i];
      const itGross = mulPaise(toPaise(it.unit_price), it.quantity);
      const itDiscount = mulPaise(toPaise(it.discount_amount ?? 0), it.quantity);
      const itTaxable = Math.max(0, itGross - itDiscount);
      const itTax = percentagePaise(itTaxable, it.tax_rate);
      subtotalPaise = addPaise(subtotalPaise, itTaxable);
      itemsDiscountPaise = addPaise(itemsDiscountPaise, itDiscount);
      taxTotalPaise = addPaise(taxTotalPaise, itTax);
    }
  }

  const discountTotalPaise = addPaise(itemsDiscountPaise, manualDiscountPaise);
  const netSubtotalPaise = Math.max(0, subtotalPaise - manualDiscountPaise);
  const deliveryChargePaise = toPaise(order.delivery_charge ?? 0);
  const grandTotalPaise = addPaise(netSubtotalPaise, taxTotalPaise, deliveryChargePaise);

  return {
    updatedOrderItem: {
      id: targetItem.id,
      quantity: newQty,
      line_total: roundMoney(toRupees(newLineTotalPaise)),
      line_total_paise: newLineTotalPaise,
    },
    updatedOrder: {
      id: order.id,
      subtotal: roundMoney(toRupees(subtotalPaise)),
      tax_total: roundMoney(toRupees(taxTotalPaise)),
      discount_total: roundMoney(toRupees(discountTotalPaise)),
      delivery_charge: roundMoney(toRupees(deliveryChargePaise)),
      grand_total: roundMoney(toRupees(grandTotalPaise)),
      subtotal_paise: subtotalPaise,
      tax_total_paise: taxTotalPaise,
      discount_total_paise: discountTotalPaise,
      delivery_charge_paise: deliveryChargePaise,
      grand_total_paise: grandTotalPaise,
    },
  };
}
