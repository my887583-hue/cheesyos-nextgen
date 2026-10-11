/**
 * CHEESYOS NEXTGEN POS CORE — KOT DISPATCH & CORRECTION ENGINE
 * 
 * Creates immutable Kitchen Order Ticket (KOT) snapshots and authorization audit logs.
 */

import { PosKotDomain, KotItemDomain, KotCorrectionDomain, OrderItemDomain } from '@cheesyos/nextgen-shared';

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
  productName: string;
  dispatchedQty: number;
  cancelledQty: number;
  reason: string;
  authorizedByStaffId: string;
}

/**
 * Creates an immutable KOT header and KOT item snapshots for kitchen printing.
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

  if (options.cancelledQty > options.dispatchedQty) {
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
    product_name: options.productName,
    cancelled_qty: options.cancelledQty,
    reason: options.reason.trim(),
    authorized_by_staff_id: options.authorizedByStaffId,
    created_at: new Date().toISOString(),
  };
}
