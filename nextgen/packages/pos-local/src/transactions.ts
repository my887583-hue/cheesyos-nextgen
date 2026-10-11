/**
 * CHEESYOS NEXTGEN POS LOCAL — ATOMIC POS TRANSACTIONS
 * 
 * Provides single-transaction operational persistence combining business rows + outbox entries.
 */

import {
  OrderDomain,
  OrderItemDomain,
  PosKotDomain,
  KotItemDomain,
  KotCorrectionDomain,
  BillDomain,
  PaymentDomain,
} from '@cheesyos/nextgen-shared';
import { toPaise, toRupees } from '@cheesyos/pos-core';
import { PosLocalDatabase } from './database.js';
import { IPosLocalDatabase } from './adapter.js';
import { insertOutboxRecord, OutboxRow } from './outbox.js';
import { getDeviceConfig, allocateNextSequence, formatBillNumber } from './device.js';

export interface SaveOrderResult {
  order: OrderDomain;
  items: OrderItemDomain[];
  outboxEntries: OutboxRow[];
}

export interface SaveKotResult {
  kot: PosKotDomain;
  items: KotItemDomain[];
  outboxEntries: OutboxRow[];
}

export interface SaveBillResult {
  bill: BillDomain;
  outboxEntry: OutboxRow;
}

export interface SaveBillWithSequenceResult extends SaveBillResult {
  sequenceNumber: number;
}

export interface SavePaymentResult {
  payment: PaymentDomain;
  updatedBill: BillDomain;
  outboxEntry: OutboxRow;
}

export interface SaveInventoryMovementInput {
  id?: string; // Movement UUID (fixed identity)
  productId: string;
  movementType: 'SALE' | 'CANCEL_RESTORE' | 'MANUAL_ADD' | 'MANUAL_REMOVE' | 'ADJUSTMENT';
  quantityChange: number;
  createdByStaffId?: string | null;
  referenceMovementId?: string | null;
  createdAt?: string;
}

export interface SaveInventoryMovementResult {
  movementId: string;
  productId: string;
  newStock: number;
  outboxEntry: OutboxRow;
}

/**
 * Atomically persists Order header, Order items, and corresponding sync outbox record.
 */
export function saveOrderTransaction(
  dbManager: IPosLocalDatabase | PosLocalDatabase,
  order: OrderDomain,
  items: OrderItemDomain[]
): SaveOrderResult {
  return dbManager.runTransaction((db) => {
    // 1. Insert Order Header
    const orderStmt = db.prepare(`
      INSERT INTO orders (
        id, display_number, channel, order_type, customer_id, table_session_id,
        status, subtotal_paise, tax_total_paise, discount_total_paise,
        delivery_charge_paise, grand_total_paise, device_id, created_at, updated_at
      ) VALUES (
        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
      )
    `);

    orderStmt.run(
      order.id,
      order.display_number ?? null,
      order.channel,
      order.order_type,
      order.customer_id ?? null,
      order.table_session_id ?? null,
      order.status,
      toPaise(order.subtotal),
      toPaise(order.tax_total),
      toPaise(order.discount_total),
      toPaise(order.delivery_charge),
      toPaise(order.grand_total),
      order.device_id ?? null,
      order.created_at,
      order.updated_at
    );

    // 2. Insert Order Items
    const itemStmt = db.prepare(`
      INSERT INTO order_items (
        id, order_id, product_id, variant_id, product_name, unit_price_paise,
        quantity, tax_rate, discount_amount_paise, line_total_paise, notes, created_at
      ) VALUES (
        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
      )
    `);

    for (const item of items) {
      itemStmt.run(
        item.id,
        item.order_id,
        item.product_id,
        item.variant_id ?? null,
        item.product_name,
        toPaise(item.unit_price),
        item.quantity,
        item.tax_rate,
        toPaise(item.discount_amount),
        toPaise(item.line_total),
        item.notes ?? null,
        item.created_at
      );
    }

    // 3. Create Outbox Entry
    const outboxRow = insertOutboxRecord(db, {
      entityType: 'orders',
      entityId: order.id,
      operation: 'INSERT',
      payload: {
        order,
        items,
      },
      createdAt: order.created_at,
    });

    return {
      order,
      items,
      outboxEntries: [outboxRow],
    };
  });
}

/**
 * Atomically persists KOT header, KOT items, and sync outbox record.
 */
export function saveKotDispatchTransaction(
  dbManager: IPosLocalDatabase | PosLocalDatabase,
  kot: PosKotDomain,
  items: KotItemDomain[]
): SaveKotResult {
  return dbManager.runTransaction((db) => {
    const kotStmt = db.prepare(`
      INSERT INTO pos_kots (
        id, order_id, kot_number, device_id, status, printed_at
      ) VALUES (
        ?, ?, ?, ?, ?, ?
      )
    `);

    kotStmt.run(
      kot.id,
      kot.order_id,
      kot.kot_number,
      kot.device_id ?? null,
      kot.status,
      kot.printed_at
    );

    const itemStmt = db.prepare(`
      INSERT INTO kot_items (
        id, kot_id, product_id, variant_id, product_name, quantity, notes
      ) VALUES (
        ?, ?, ?, ?, ?, ?, ?
      )
    `);

    for (const item of items) {
      itemStmt.run(
        item.id,
        item.kot_id,
        item.product_id,
        item.variant_id ?? null,
        item.product_name,
        item.quantity,
        item.notes ?? null
      );
    }

    const outboxRow = insertOutboxRecord(db, {
      entityType: 'pos_kots',
      entityId: kot.id,
      operation: 'INSERT',
      payload: {
        kot,
        items,
      },
      createdAt: kot.printed_at,
    });

    return {
      kot,
      items,
      outboxEntries: [outboxRow],
    };
  });
}

/**
 * Atomically persists KOT correction audit entry and sync outbox record.
 */
export function saveKotCorrectionTransaction(
  dbManager: IPosLocalDatabase | PosLocalDatabase,
  correction: KotCorrectionDomain
): OutboxRow {
  return dbManager.runTransaction((db) => {
    const stmt = db.prepare(`
      INSERT INTO kot_corrections (
        id, order_id, kot_id, product_name, cancelled_qty, reason,
        authorized_by_staff_id, created_at
      ) VALUES (
        ?, ?, ?, ?, ?, ?, ?, ?
      )
    `);

    stmt.run(
      correction.id,
      correction.order_id,
      correction.kot_id ?? null,
      correction.product_name,
      correction.cancelled_qty,
      correction.reason,
      correction.authorized_by_staff_id,
      correction.created_at
    );

    return insertOutboxRecord(db, {
      entityType: 'kot_corrections',
      entityId: correction.id,
      operation: 'INSERT',
      payload: { correction },
      createdAt: correction.created_at,
    });
  });
}

/**
 * Atomically persists Bill header and sync outbox record.
 */
export function saveBillTransaction(
  dbManager: IPosLocalDatabase | PosLocalDatabase,
  bill: BillDomain
): SaveBillResult {
  return dbManager.runTransaction((db) => {
    const stmt = db.prepare(`
      INSERT INTO bills (
        id, order_id, bill_number, subtotal_paise, cgst_total_paise,
        sgst_total_paise, discount_total_paise, grand_total_paise,
        payment_status, finalized_at, device_id
      ) VALUES (
        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
      )
    `);

    stmt.run(
      bill.id,
      bill.order_id,
      bill.bill_number,
      toPaise(bill.subtotal),
      toPaise(bill.cgst_total),
      toPaise(bill.sgst_total),
      toPaise(bill.discount_total),
      toPaise(bill.grand_total),
      bill.payment_status,
      bill.finalized_at,
      bill.device_id ?? null
    );

    const outboxRow = insertOutboxRecord(db, {
      entityType: 'bills',
      entityId: bill.id,
      operation: 'INSERT',
      payload: { bill },
      createdAt: bill.finalized_at,
    });

    return {
      bill,
      outboxEntry: outboxRow,
    };
  });
}

/**
 * Atomically allocates next sequential bill number, persists Bill header,
 * and creates sync outbox record within a single database transaction.
 * 
 * Guarantees:
 * - Authoritative bill number generated from terminal_code + sequence_number.
 * - Caller-provided bill_number is rejected if non-empty and conflicting with allocated sequence.
 * - Single atomic transaction: rollback restores sequence counter and prevents orphaned outbox entries.
 */
export function saveBillWithSequenceTransaction(
  dbManager: IPosLocalDatabase | PosLocalDatabase,
  bill: BillDomain
): SaveBillWithSequenceResult {
  return dbManager.runTransaction((db) => {
    const config = getDeviceConfig(db);
    if (!config) {
      throw new Error('[PosPersistence] Terminal device identity is not configured locally. Bill allocation rejected.');
    }

    const sequenceNumber = allocateNextSequence(db, 'bill_sequence');
    const authoritativeBillNumber = formatBillNumber(config.terminal_code, sequenceNumber);

    if (
      bill.bill_number &&
      !['PENDING', 'DRAFT', 'TEMP', 'UNASSIGNED', ''].includes(bill.bill_number.trim().toUpperCase()) &&
      bill.bill_number !== authoritativeBillNumber
    ) {
      throw new Error(
        `[PosPersistence] BILL_NUMBER_CONFLICT: Caller-provided bill_number "${bill.bill_number}" conflicts with allocated sequence number "${authoritativeBillNumber}". Authority is SAVE_BILL_WITH_SEQUENCE_TRANSACTION.`
      );
    }

    const authoritativeBill: BillDomain = {
      ...bill,
      bill_number: authoritativeBillNumber,
      device_id: config.device_id,
    };

    const stmt = db.prepare(`
      INSERT INTO bills (
        id, order_id, bill_number, subtotal_paise, cgst_total_paise,
        sgst_total_paise, discount_total_paise, grand_total_paise,
        payment_status, finalized_at, device_id
      ) VALUES (
        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
      )
    `);

    stmt.run(
      authoritativeBill.id,
      authoritativeBill.order_id,
      authoritativeBill.bill_number,
      toPaise(authoritativeBill.subtotal),
      toPaise(authoritativeBill.cgst_total),
      toPaise(authoritativeBill.sgst_total),
      toPaise(authoritativeBill.discount_total),
      toPaise(authoritativeBill.grand_total),
      authoritativeBill.payment_status,
      authoritativeBill.finalized_at,
      authoritativeBill.device_id ?? null
    );

    const outboxRow = insertOutboxRecord(db, {
      entityType: 'bills',
      entityId: authoritativeBill.id,
      operation: 'INSERT',
      payload: { bill: authoritativeBill },
      createdAt: authoritativeBill.finalized_at,
    });

    return {
      bill: authoritativeBill,
      sequenceNumber,
      outboxEntry: outboxRow,
    };
  });
}

/**
 * Atomically persists Payment settlement record, updates bill status, and creates sync outbox record.
 */
export function savePaymentTransaction(
  dbManager: IPosLocalDatabase | PosLocalDatabase,
  payment: PaymentDomain,
  updatedBill: BillDomain
): SavePaymentResult {
  return dbManager.runTransaction((db) => {
    // 1. Insert Payment Record
    const payStmt = db.prepare(`
      INSERT INTO payments (
        id, bill_id, order_id, payment_mode, amount_paid_paise,
        confirmed_by_staff_id, confirmed_at, notes
      ) VALUES (
        ?, ?, ?, ?, ?, ?, ?, ?
      )
    `);

    payStmt.run(
      payment.id,
      payment.bill_id,
      payment.order_id,
      payment.payment_mode,
      toPaise(payment.amount_paid),
      payment.confirmed_by_staff_id ?? null,
      payment.confirmed_at,
      payment.notes ?? null
    );

    // 2. Update Bill Payment Status
    const billStmt = db.prepare(`
      UPDATE bills
      SET payment_status = ?
      WHERE id = ?
    `);

    billStmt.run(updatedBill.payment_status, updatedBill.id);

    // 3. Create Outbox Entry
    const outboxRow = insertOutboxRecord(db, {
      entityType: 'payments',
      entityId: payment.id,
      operation: 'INSERT',
      payload: {
        payment,
        paymentStatus: updatedBill.payment_status,
      },
      createdAt: payment.confirmed_at,
    });

    return {
      payment,
      updatedBill,
      outboxEntry: outboxRow,
    };
  });
}

/**
 * Atomically records local inventory deduction/movement and creates sync outbox record with fixed movement UUID.
 */
export function saveInventoryMovementTransaction(
  dbManager: IPosLocalDatabase | PosLocalDatabase,
  input: SaveInventoryMovementInput
): SaveInventoryMovementResult {
  return dbManager.runTransaction((db) => {
    const movementId = input.id || crypto.randomUUID();
    const createdAt = input.createdAt || new Date().toISOString();

    // 1. Insert Movement Entry
    const moveStmt = db.prepare(`
      INSERT INTO inventory_movements (
        id, product_id, movement_type, quantity_change, created_by, reference_movement_id, created_at
      ) VALUES (
        ?, ?, ?, ?, ?, ?, ?
      )
    `);

    moveStmt.run(
      movementId,
      input.productId,
      input.movementType,
      input.quantityChange,
      input.createdByStaffId ?? null,
      input.referenceMovementId ?? null,
      createdAt
    );

    // 2. Update Local Stock Count if tracked
    const stockStmt = db.prepare(`
      UPDATE inventory_lite
      SET current_stock = current_stock + ?,
          updated_at = ?
      WHERE product_id = ?
    `);

    stockStmt.run(input.quantityChange, createdAt, input.productId);

    // Read updated stock count
    const readStmt = db.prepare(`SELECT current_stock FROM inventory_lite WHERE product_id = ?`);
    const stockRow = readStmt.get(input.productId) as { current_stock: number } | undefined;
    const newStock = stockRow?.current_stock ?? 0;

    // 3. Insert Outbox Record with fixed movement identity
    const outboxRow = insertOutboxRecord(db, {
      entityType: 'inventory_movements',
      entityId: movementId,
      operation: 'INSERT',
      payload: {
        movementId,
        productId: input.productId,
        quantityChange: input.quantityChange,
        movementType: input.movementType,
        createdByStaffId: input.createdByStaffId ?? null,
        referenceMovementId: input.referenceMovementId ?? null,
        createdAt,
      },
      createdAt,
    });

    return {
      movementId,
      productId: input.productId,
      newStock,
      outboxEntry: outboxRow,
    };
  });
}
