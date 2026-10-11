/**
 * CHEESYOS NEXTGEN POS CORE — BILL FINALIZATION ENGINE
 * 
 * Generates fiscal invoice summaries and CGST/SGST tax breakdowns from order snapshots.
 */

import { BillDomain, OrderDomain, roundMoney } from '@cheesyos/nextgen-shared';
import { toPaise, toRupees } from './money.js';

export interface FinalizeBillOptions {
  billId?: string;
  billNumber: string; // e.g. "CB-K01-000123"
  deviceId?: string | null;
}

/**
 * Creates an immutable Bill domain record from a frozen Order domain snapshot.
 */
export function finalizeBill(
  order: OrderDomain,
  options: FinalizeBillOptions
): BillDomain {
  if (!options.billNumber || options.billNumber.trim().length === 0) {
    throw new Error('[BillingEngine] Bill number display string is required to finalize bill');
  }

  if (order.grand_total < 0) {
    throw new Error('[BillingEngine] Cannot finalize bill for an order with negative grand total');
  }

  const billId = options.billId || crypto.randomUUID();
  const finalizedAt = new Date().toISOString();

  // CGST / SGST 50-50 Split using integer Paise
  const taxTotalPaise = toPaise(order.tax_total);
  const cgstPaise = Math.floor(taxTotalPaise / 2);
  const sgstPaise = taxTotalPaise - cgstPaise;

  return {
    id: billId,
    order_id: order.id,
    bill_number: options.billNumber.trim(),
    subtotal: roundMoney(order.subtotal),
    cgst_total: roundMoney(toRupees(cgstPaise)),
    sgst_total: roundMoney(toRupees(sgstPaise)),
    discount_total: roundMoney(order.discount_total),
    grand_total: roundMoney(order.grand_total),
    payment_status: 'unpaid',
    finalized_at: finalizedAt,
    device_id: options.deviceId ?? order.device_id ?? null,
  };
}
