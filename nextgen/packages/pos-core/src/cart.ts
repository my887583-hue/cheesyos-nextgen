/**
 * CHEESYOS NEXTGEN POS CORE — CART MODEL & FINANCIAL CALCULATION
 * 
 * Pure, deterministic cart engine for POS order composition.
 */

import { OrderChannel, OrderType } from '@cheesyos/nextgen-shared';
import { toPaise, toRupees, addPaise, mulPaise, percentagePaise, MoneyPaise } from './money.js';

export interface CartItemInput {
  productId: string;
  variantId?: string | null;
  productName: string;
  unitPriceRupees: number;
  quantity?: number;
  taxRatePercent?: number; // e.g. 5.00 for 5%
  discountAmountRupees?: number;
  notes?: string | null;
}

export interface CartItem {
  id: string; // Transient item line identifier in cart
  productId: string;
  variantId?: string | null;
  productName: string;
  unitPricePaise: MoneyPaise;
  quantity: number;
  taxRatePercent: number;
  discountAmountPaise: MoneyPaise;
  taxableLinePaise: MoneyPaise;
  taxLinePaise: MoneyPaise;
  lineTotalPaise: MoneyPaise;
  notes?: string | null;
}

export interface CartTotals {
  subtotalPaise: MoneyPaise;
  discountTotalPaise: MoneyPaise;
  taxTotalPaise: MoneyPaise;
  deliveryChargePaise: MoneyPaise;
  grandTotalPaise: MoneyPaise;
  // Decimal Rupee representation for UI & API boundaries
  subtotalRupees: number;
  discountTotalRupees: number;
  taxTotalRupees: number;
  deliveryChargeRupees: number;
  grandTotalRupees: number;
}

export interface CartState {
  channel: OrderChannel;
  orderType: OrderType;
  customerId?: string | null;
  tableSessionId?: string | null;
  items: CartItem[];
  deliveryChargeRupees: number;
  manualDiscountRupees: number;
}

export class PosCart {
  private state: CartState;

  constructor(initialState?: Partial<CartState>) {
    this.state = {
      channel: 'POS',
      orderType: initialState?.orderType || 'DINE_IN',
      customerId: initialState?.customerId || null,
      tableSessionId: initialState?.tableSessionId || null,
      items: initialState?.items || [],
      deliveryChargeRupees: initialState?.deliveryChargeRupees || 0,
      manualDiscountRupees: initialState?.manualDiscountRupees || 0,
    };
  }

  public getState(): Readonly<CartState> {
    return this.state;
  }

  public setOrderType(orderType: OrderType): void {
    this.state.orderType = orderType;
  }

  public setCustomer(customerId: string | null): void {
    this.state.customerId = customerId;
  }

  public setTableSession(tableSessionId: string | null): void {
    this.state.tableSessionId = tableSessionId;
  }

  public setDeliveryCharge(amountRupees: number): void {
    if (amountRupees < 0) {
      throw new Error('[PosCart] Delivery charge cannot be negative');
    }
    this.state.deliveryChargeRupees = amountRupees;
  }

  public setManualDiscount(amountRupees: number): void {
    if (amountRupees < 0) {
      throw new Error('[PosCart] Manual discount cannot be negative');
    }
    this.state.manualDiscountRupees = amountRupees;
  }

  public addItem(input: CartItemInput): CartItem {
    const qty = input.quantity ?? 1;
    if (qty <= 0) {
      throw new Error('[PosCart] Item quantity must be greater than 0');
    }

    const unitPricePaise = toPaise(input.unitPriceRupees);
    const taxRatePercent = input.taxRatePercent ?? 5.0; // Default 5% GST
    const discountAmountPaise = toPaise(input.discountAmountRupees ?? 0);

    // Look for existing identical item in cart (same product_id, variant_id, and notes)
    const existingIndex = this.state.items.findIndex(
      (item) =>
        item.productId === input.productId &&
        (item.variantId ?? null) === (input.variantId ?? null) &&
        (item.notes ?? '') === (input.notes ?? '')
    );

    if (existingIndex >= 0) {
      const existing = this.state.items[existingIndex];
      const newQty = existing.quantity + qty;
      return this.updateQuantity(existing.id, newQty);
    }

    const lineId = `cart-item-${Date.now()}-${Math.random().toString(36).substring(2, 7)}`;
    const newItem = this.buildCartItem({
      id: lineId,
      productId: input.productId,
      variantId: input.variantId ?? null,
      productName: input.productName,
      unitPricePaise,
      quantity: qty,
      taxRatePercent,
      discountAmountPaise,
      notes: input.notes ?? null,
    });

    this.state.items.push(newItem);
    return newItem;
  }

  public updateQuantity(itemId: string, newQuantity: number): CartItem {
    const itemIndex = this.state.items.findIndex((item) => item.id === itemId);
    if (itemIndex < 0) {
      throw new Error(`[PosCart] Cart item not found: ${itemId}`);
    }

    if (newQuantity <= 0) {
      const removed = this.state.items[itemIndex];
      this.state.items.splice(itemIndex, 1);
      return removed;
    }

    const existing = this.state.items[itemIndex];
    const updated = this.buildCartItem({
      ...existing,
      quantity: newQuantity,
    });

    this.state.items[itemIndex] = updated;
    return updated;
  }

  public removeItem(itemId: string): void {
    this.state.items = this.state.items.filter((item) => item.id !== itemId);
  }

  public clear(): void {
    this.state.items = [];
    this.state.manualDiscountRupees = 0;
    this.state.deliveryChargeRupees = 0;
  }

  public calculateTotals(): CartTotals {
    let subtotalPaise = 0;
    let itemsDiscountPaise = 0;
    let taxTotalPaise = 0;

    for (const item of this.state.items) {
      subtotalPaise = addPaise(subtotalPaise, item.taxableLinePaise);
      itemsDiscountPaise = addPaise(itemsDiscountPaise, mulPaise(item.discountAmountPaise, item.quantity));
      taxTotalPaise = addPaise(taxTotalPaise, item.taxLinePaise);
    }

    const manualDiscountPaise = toPaise(this.state.manualDiscountRupees);
    const discountTotalPaise = addPaise(itemsDiscountPaise, manualDiscountPaise);

    // Apply manual discount against subtotal if present
    const netSubtotalPaise = Math.max(0, subtotalPaise - manualDiscountPaise);

    const deliveryChargePaise = toPaise(this.state.deliveryChargeRupees);
    const grandTotalPaise = addPaise(netSubtotalPaise, taxTotalPaise, deliveryChargePaise);

    return {
      subtotalPaise,
      discountTotalPaise,
      taxTotalPaise,
      deliveryChargePaise,
      grandTotalPaise,
      subtotalRupees: toRupees(subtotalPaise),
      discountTotalRupees: toRupees(discountTotalPaise),
      taxTotalRupees: toRupees(taxTotalPaise),
      deliveryChargeRupees: toRupees(deliveryChargePaise),
      grandTotalRupees: toRupees(grandTotalPaise),
    };
  }

  private buildCartItem(params: {
    id: string;
    productId: string;
    variantId?: string | null;
    productName: string;
    unitPricePaise: MoneyPaise;
    quantity: number;
    taxRatePercent: number;
    discountAmountPaise: MoneyPaise;
    notes?: string | null;
  }): CartItem {
    const grossLinePaise = mulPaise(params.unitPricePaise, params.quantity);
    const itemDiscountPaise = mulPaise(params.discountAmountPaise, params.quantity);
    const taxableLinePaise = Math.max(0, grossLinePaise - itemDiscountPaise);
    const taxLinePaise = percentagePaise(taxableLinePaise, params.taxRatePercent);
    const lineTotalPaise = addPaise(taxableLinePaise, taxLinePaise);

    return {
      id: params.id,
      productId: params.productId,
      variantId: params.variantId ?? null,
      productName: params.productName,
      unitPricePaise: params.unitPricePaise,
      quantity: params.quantity,
      taxRatePercent: params.taxRatePercent,
      discountAmountPaise: params.discountAmountPaise,
      taxableLinePaise,
      taxLinePaise,
      lineTotalPaise,
      notes: params.notes ?? null,
    };
  }
}
