/**
 * CHEESYOS NEXTGEN POS CORE — UNIT & INVARIANT TEST SUITE
 * Standard Node test runner assertions verifying financial precision and business rules.
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import {
  toPaise,
  toRupees,
  addPaise,
  subPaise,
  mulPaise,
  percentagePaise,
  PosCart,
  createOrderDraft,
  createKotDispatchSnapshot,
  createKotCorrection,
  finalizeBill,
  confirmPayment,
} from '../src/index.js';

describe('1. Money Engine Arithmetic Precision', () => {
  test('E & F. Integer money conversion & ₹99 / ₹129 / ₹129.99 exact calculations', () => {
    assert.equal(toPaise(129.0), 12900);
    assert.equal(toPaise(99.0), 9900);
    assert.equal(toPaise(129.99), 12999);
    assert.equal(toRupees(12900), 129.0);
    assert.equal(toRupees(9900), 99.0);
    assert.equal(toRupees(12999), 129.99);

    const subtotalPaise = addPaise(toPaise(129.0), toPaise(99.0));
    assert.equal(subtotalPaise, 22800);
    assert.equal(toRupees(subtotalPaise), 228.0);
  });

  test('Percentage tax calculation in paise resolves rounding deterministically', () => {
    // 5% tax on ₹129.00 (12900 paise) = 645 paise (₹6.45)
    const taxPaise1 = percentagePaise(12900, 5.0);
    assert.equal(taxPaise1, 645);
    assert.equal(toRupees(taxPaise1), 6.45);

    // 5% tax on ₹129.99 (12999 paise) = 649.95 paise -> rounds to 650 paise (₹6.50)
    const taxPaise2 = percentagePaise(12999, 5.0);
    assert.equal(taxPaise2, 650);
    assert.equal(toRupees(taxPaise2), 6.50);
  });

  test('Rejects invalid money inputs (NaN, Infinity)', () => {
    assert.throws(() => toPaise(NaN), /Invalid Rupee amount/);
    assert.throws(() => toPaise(Infinity), /Invalid Rupee amount/);
    assert.throws(() => toRupees(NaN), /Invalid Paise amount/);
    assert.throws(() => toRupees(Infinity), /Invalid Paise amount/);
  });
});

describe('2. Cart Model & Tax Source-of-Truth', () => {
  test('A. Add one item to cart', () => {
    const cart = new PosCart();
    const item = cart.addItem({
      productId: 'p-101',
      productName: 'Paneer Butter Masala',
      unitPriceRupees: 250.0,
      quantity: 1,
      taxRatePercent: 5.0,
    });

    assert.equal(cart.getState().items.length, 1);
    assert.equal(item.quantity, 1);
    assert.equal(item.unitPricePaise, 25000);
    assert.equal(item.taxableLinePaise, 25000);
    assert.equal(item.taxLinePaise, 1250); // 5% of 25000 = 1250 paise (₹12.50)
    assert.equal(item.lineTotalPaise, 26250); // ₹262.50
  });

  test('B. Add same item increments quantity', () => {
    const cart = new PosCart();
    cart.addItem({
      productId: 'p-101',
      productName: 'Paneer Butter Masala',
      unitPriceRupees: 250.0,
      quantity: 1,
    });
    const updated = cart.addItem({
      productId: 'p-101',
      productName: 'Paneer Butter Masala',
      unitPriceRupees: 250.0,
      quantity: 2,
    });

    assert.equal(cart.getState().items.length, 1);
    assert.equal(updated.quantity, 3);
  });

  test('C & T. Decrease item quantity and reject invalid quantity', () => {
    const cart = new PosCart();
    const item = cart.addItem({
      productId: 'p-102',
      productName: 'Garlic Naan',
      unitPriceRupees: 40.0,
      quantity: 5,
    });

    const decremented = cart.updateQuantity(item.id, 2);
    assert.equal(decremented.quantity, 2);

    // Setting qty to 0 removes item
    cart.updateQuantity(item.id, 0);
    assert.equal(cart.getState().items.length, 0);

    // Adding negative quantity throws error
    assert.throws(() => {
      cart.addItem({
        productId: 'p-102',
        productName: 'Garlic Naan',
        unitPriceRupees: 40.0,
        quantity: -1,
      });
    }, /quantity must be greater than 0/);
  });

  test('D, G, H. Per-product configurable tax rates (5%, 18%, 0%)', () => {
    const cart = new PosCart();
    // Item 1: Beverage @ ₹100 (18% GST)
    cart.addItem({
      productId: 'p-beverage',
      productName: 'Red Bull 250ml',
      unitPriceRupees: 100.0,
      quantity: 1,
      taxRatePercent: 18.0, // Tax = ₹18.00
    });
    // Item 2: Food @ ₹200 (5% GST)
    cart.addItem({
      productId: 'p-food',
      productName: 'Veg Pizza',
      unitPriceRupees: 200.0,
      quantity: 1,
      taxRatePercent: 5.0, // Tax = ₹10.00
    });
    // Item 3: Water @ ₹20 (0% GST)
    cart.addItem({
      productId: 'p-water',
      productName: 'Mineral Water',
      unitPriceRupees: 20.0,
      quantity: 1,
      taxRatePercent: 0.0, // Tax = ₹0.00
    });

    const totals = cart.calculateTotals();
    assert.equal(totals.subtotalRupees, 320.0); // 100 + 200 + 20 = 320
    assert.equal(totals.taxTotalRupees, 28.0); // 18 + 10 + 0 = 28.00
    assert.equal(totals.grandTotalRupees, 348.0); // 320 + 28 = 348.00
  });
});

describe('3. Order Draft Engine', () => {
  test('I. Empty cart rejected for order creation', () => {
    const cart = new PosCart();
    assert.throws(() => {
      createOrderDraft(cart);
    }, /Cannot create order draft from an empty cart/);
  });

  test('J. Order item price & tax snapshots remain unchanged after catalog mutation', () => {
    const cart = new PosCart();
    const productCatalog = { id: 'prod-1', name: 'Cold Coffee', price: 120.0, taxRate: 5.0 };

    cart.addItem({
      productId: productCatalog.id,
      productName: productCatalog.name,
      unitPriceRupees: productCatalog.price,
      taxRatePercent: productCatalog.taxRate,
      quantity: 2,
    });

    const draft = createOrderDraft(cart, { displayNumber: 'CB-K01-0001' });

    // Mutate catalog source price and tax rate
    productCatalog.price = 180.0;
    productCatalog.taxRate = 18.0;

    // Order snapshot remains strictly at ₹120.00 and 5% tax
    assert.equal(draft.items[0].unit_price, 120.0);
    assert.equal(draft.items[0].tax_rate, 5.0);
    assert.equal(draft.order.subtotal, 240.0);
    assert.equal(draft.order.tax_total, 12.0); // 5% of 240
  });
});

describe('4. KOT Dispatch & Correction Engine', () => {
  test('K. KOT snapshot remains unchanged after subsequent cart mutation', () => {
    const cart = new PosCart();
    cart.addItem({
      productId: 'p-pizza',
      productName: 'Cheese Pizza',
      unitPriceRupees: 350.0,
      quantity: 1,
    });

    const draft = createOrderDraft(cart);
    const kotResult = createKotDispatchSnapshot(draft.order.id, draft.items, { kotNumber: 101 });

    assert.equal(kotResult.items.length, 1);
    assert.equal(kotResult.items[0].quantity, 1);

    // Cart mutates afterwards
    cart.addItem({
      productId: 'p-coke',
      productName: 'Coke 300ml',
      unitPriceRupees: 40.0,
      quantity: 2,
    });

    // KOT snapshot 101 is immutable and unaffected
    assert.equal(kotResult.items.length, 1);
    assert.equal(kotResult.items[0].product_name, 'Cheese Pizza');
  });

  test('L. KOT correction creates audit log and rejects invalid cancellation bounds', () => {
    const cart = new PosCart();
    cart.addItem({
      productId: 'p-pizza',
      productName: 'Cheese Pizza',
      unitPriceRupees: 350.0,
      quantity: 2,
    });

    const draft = createOrderDraft(cart);
    const kotResult = createKotDispatchSnapshot(draft.order.id, draft.items, { kotNumber: 102 });

    // Reject cancellation exceeding dispatched quantity
    assert.throws(() => {
      createKotCorrection({
        orderId: draft.order.id,
        kotId: kotResult.kot.id,
        productName: 'Cheese Pizza',
        dispatchedQty: 2,
        cancelledQty: 3,
        reason: 'Customer changed mind',
        authorizedByStaffId: 'staff-mgr-101',
      });
    }, /Cannot cancel 3 units when only 2 were dispatched/);

    const correction = createKotCorrection({
      orderId: draft.order.id,
      kotId: kotResult.kot.id,
      productName: 'Cheese Pizza',
      dispatchedQty: 2,
      cancelledQty: 1,
      reason: 'Customer changed mind',
      authorizedByStaffId: 'staff-mgr-101',
    });

    assert.equal(correction.cancelled_qty, 1);
    assert.equal(correction.reason, 'Customer changed mind');
    // Original KOT item snapshot remains untouched at 2
    assert.equal(kotResult.items[0].quantity, 2);
  });
});

describe('5. Bill Finalization Engine', () => {
  test('M. Bill total comes from transaction snapshot & handles odd-paise CGST/SGST split', () => {
    const cart = new PosCart();
    cart.addItem({
      productId: 'p-fries',
      productName: 'French Fries',
      unitPriceRupees: 129.0,
      quantity: 1,
      taxRatePercent: 5.0, // Tax = 645 paise (₹6.45)
    });

    const draft = createOrderDraft(cart);
    const bill = finalizeBill(draft.order, { billNumber: 'CB-K01-000501' });

    assert.equal(bill.subtotal, 129.0);
    assert.equal(bill.grand_total, 135.45);
    // CGST: Math.floor(645 / 2) = 322 paise (₹3.22)
    // SGST: 645 - 322 = 323 paise (₹3.23)
    // CGST + SGST = 3.22 + 3.23 = 6.45 exact
    assert.equal(bill.cgst_total, 3.22);
    assert.equal(bill.sgst_total, 3.23);
    assert.equal(bill.cgst_total + bill.sgst_total, bill.subtotal === 129.0 ? 6.45 : 0);
    assert.equal(bill.payment_status, 'unpaid');
  });
});

describe('6. Manual Settlement & Split Payment Engine', () => {
  test('N, O, P, Q, R, S. Manual Cash/UPI/Card payment, split settlement, overpayment check', () => {
    const cart = new PosCart();
    cart.addItem({
      productId: 'p-feast',
      productName: 'Family Feast',
      unitPriceRupees: 1000.0,
      quantity: 1,
      taxRatePercent: 0,
    });

    const draft = createOrderDraft(cart);
    const bill = finalizeBill(draft.order, { billNumber: 'CB-K01-000999' });

    // Step 1: Reject zero or negative payment amounts
    assert.throws(() => {
      confirmPayment({ bill, paymentMode: 'CASH', amountPaidRupees: 0 });
    }, /Payment amount must be greater than 0/);

    assert.throws(() => {
      confirmPayment({ bill, paymentMode: 'CASH', amountPaidRupees: -50 });
    }, /Payment amount must be greater than 0/);

    // Step 2: Cash payment of ₹400 -> Partially Paid
    const settlement1 = confirmPayment({
      bill,
      paymentMode: 'CASH',
      amountPaidRupees: 400.0,
      confirmedByStaffId: 'staff-cashier-1',
    });

    assert.equal(settlement1.updatedBill.payment_status, 'partially_paid');
    assert.equal(settlement1.remainingBalanceRupees, 600.0);
    assert.equal(settlement1.isFullySettled, false);

    // Step 3: Overpayment check (attempting to pay ₹700 when only ₹600 is remaining)
    assert.throws(() => {
      confirmPayment({
        bill: settlement1.updatedBill,
        existingPayments: [settlement1.payment],
        paymentMode: 'UPI',
        amountPaidRupees: 700.0,
      });
    }, /exceeds bill balance/);

    // Step 4: UPI payment of remaining ₹600 -> Fully Settled ('paid')
    const settlement2 = confirmPayment({
      bill: settlement1.updatedBill,
      existingPayments: [settlement1.payment],
      paymentMode: 'UPI',
      amountPaidRupees: 600.0,
      confirmedByStaffId: 'staff-cashier-1',
    });

    assert.equal(settlement2.updatedBill.payment_status, 'paid');
    assert.equal(settlement2.remainingBalanceRupees, 0.0);
    assert.equal(settlement2.isFullySettled, true);
    assert.equal(settlement2.paidTotalRupees, 1000.0);
  });
});
