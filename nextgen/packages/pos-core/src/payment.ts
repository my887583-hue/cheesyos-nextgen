/**
 * CHEESYOS NEXTGEN POS CORE — MANUAL PAYMENT & SETTLEMENT ENGINE
 * 
 * Handles cashier manual payment settlement, split-payments, and bill payment status updates.
 */

import { BillDomain, PaymentDomain, PaymentMode, PaymentStatus, roundMoney } from '@cheesyos/nextgen-shared';
import { toPaise, toRupees, addPaise } from './money.js';

export interface ConfirmPaymentInput {
  paymentId?: string;
  bill: BillDomain;
  existingPayments?: PaymentDomain[];
  paymentMode: PaymentMode;
  amountPaidRupees: number;
  confirmedByStaffId?: string | null;
  notes?: string | null;
  allowOverpayment?: boolean;
}

export interface SettlementResult {
  payment: PaymentDomain;
  updatedBill: BillDomain;
  paidTotalRupees: number;
  remainingBalanceRupees: number;
  isFullySettled: boolean;
}

/**
 * Confirms a cashier manual payment against a Bill.
 * Computes split payments and updates bill payment status.
 */
export function confirmPayment(input: ConfirmPaymentInput): SettlementResult {
  if (input.amountPaidRupees <= 0) {
    throw new Error('[PaymentEngine] Payment amount must be greater than 0');
  }

  const allowedModes: PaymentMode[] = ['CASH', 'UPI', 'CARD', 'OTHER'];
  if (!allowedModes.includes(input.paymentMode)) {
    throw new Error(`[PaymentEngine] Invalid payment mode: ${input.paymentMode}`);
  }

  const existingPayments = input.existingPayments || [];
  const previousPaidPaise = existingPayments.reduce(
    (acc, p) => addPaise(acc, toPaise(p.amount_paid)),
    0
  );

  const newPaymentPaise = toPaise(input.amountPaidRupees);
  const totalPaidPaise = addPaise(previousPaidPaise, newPaymentPaise);
  const billGrandTotalPaise = toPaise(input.bill.grand_total);

  if (!input.allowOverpayment && totalPaidPaise > billGrandTotalPaise) {
    const overpaidRupees = toRupees(totalPaidPaise - billGrandTotalPaise);
    throw new Error(
      `[PaymentEngine] Payment of ₹${input.amountPaidRupees} exceeds bill balance by ₹${overpaidRupees}`
    );
  }

  const paymentId = input.paymentId || crypto.randomUUID();
  const confirmedAt = new Date().toISOString();

  const newPayment: PaymentDomain = {
    id: paymentId,
    bill_id: input.bill.id,
    order_id: input.bill.order_id,
    payment_mode: input.paymentMode,
    amount_paid: roundMoney(toRupees(newPaymentPaise)),
    confirmed_by_staff_id: input.confirmedByStaffId ?? null,
    confirmed_at: confirmedAt,
    notes: input.notes ?? null,
  };

  const remainingPaise = Math.max(0, billGrandTotalPaise - totalPaidPaise);
  let newStatus: PaymentStatus = 'unpaid';

  if (totalPaidPaise >= billGrandTotalPaise) {
    newStatus = 'paid';
  } else if (totalPaidPaise > 0) {
    newStatus = 'partially_paid';
  }

  const updatedBill: BillDomain = {
    ...input.bill,
    payment_status: newStatus,
  };

  return {
    payment: newPayment,
    updatedBill,
    paidTotalRupees: toRupees(totalPaidPaise),
    remainingBalanceRupees: toRupees(remainingPaise),
    isFullySettled: newStatus === 'paid',
  };
}
