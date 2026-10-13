/**
 * CHEESYOS NEXTGEN POS LOCAL — ATOMIC POS TRANSACTIONS
 * 
 * Provides single-transaction operational persistence combining business rows + outbox entries.
 */

import { randomUUID } from 'node:crypto';
import {
  OrderDomain,
  OrderItemDomain,
  PosKotDomain,
  KotItemDomain,
  KotCorrectionDomain,
  BillDomain,
  PaymentDomain,
  TableSessionDomain,
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

export interface AppendOrderItemsAndKotResult {
  order: OrderDomain;
  newItems: OrderItemDomain[];
  kot: PosKotDomain;
  kotItems: KotItemDomain[];
  outboxEntries: OutboxRow[];
}

export interface ApplyKotCorrectionInput {
  correction: KotCorrectionDomain;
  updatedOrderItem: OrderItemDomain;
  updatedOrder: OrderDomain;
}

export interface ApplyKotCorrectionLocalResult {
  correction: KotCorrectionDomain;
  updatedOrderItem: OrderItemDomain;
  updatedOrder: OrderDomain;
  outboxEntry: OutboxRow;
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
    // Validate session & guard active order for dine-in
    if (order.table_session_id) {
      const session = db.prepare(`SELECT id, session_status, current_order_id FROM table_sessions WHERE id = ?`).get(order.table_session_id) as { id: string; session_status: string; current_order_id: string | null } | undefined;
      if (!session) {
        throw new Error(`[PosPersistence] SESSION_NOT_FOUND: Table session ${order.table_session_id} does not exist`);
      }
      if (session.session_status !== 'open') {
        throw new Error(`[PosPersistence] SESSION_NOT_ACTIVE: Table session ${order.table_session_id} has status '${session.session_status}', ordering not permitted`);
      }
      const existingActive = db.prepare(`
        SELECT id FROM orders
        WHERE table_session_id = ? AND id != ? AND status NOT IN ('cancelled', 'closed')
        LIMIT 1
      `).get(order.table_session_id, order.id) as { id: string } | undefined;
      if (existingActive) {
        throw new Error(`[PosPersistence] ACTIVE_ORDER_EXISTS: Table session ${order.table_session_id} already has an active order (${existingActive.id})`);
      }
    }

    const version = order.version ?? 1;

    // 1. Insert Order Header
    const orderStmt = db.prepare(`
      INSERT INTO orders (
        id, display_number, channel, order_type, customer_id, table_session_id,
        status, subtotal_paise, tax_total_paise, discount_total_paise,
        delivery_charge_paise, grand_total_paise, device_id, version, created_at, updated_at
      ) VALUES (
        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
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
      version,
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

    // 3. Set table_sessions.current_order_id atomically for dine-in session
    if (order.table_session_id) {
      db.prepare(`UPDATE table_sessions SET current_order_id = ? WHERE id = ?`).run(order.id, order.table_session_id);
    }

    const orderWithVersion: OrderDomain = {
      ...order,
      version,
    };

    // 4. Create Outbox Entry
    const outboxRow = insertOutboxRecord(db, {
      entityType: 'orders',
      entityId: order.id,
      operation: 'INSERT',
      payload: {
        order: orderWithVersion,
        items,
      },
      createdAt: order.created_at,
    });

    return {
      order: orderWithVersion,
      items,
      outboxEntries: [outboxRow],
    };
  });
}

/**
 * Atomically replaces a PRE-KOT draft order aggregate and emits an UPDATE outbox entry.
 * Enforces:
 * - Existing order exists and status == 'draft'
 * - Zero KOTs have been dispatched for this order
 * - Same table session linkage
 * - Monotonic version increment: incoming version == existing.version + 1
 * - Atomic item replacement (delete old draft items, insert replacement items)
 * - Atomic financial header and version update
 * - Emits operation: 'UPDATE' in pos_sync_outbox in the same transaction
 */
export function replaceDraftOrderAggregateTransaction(
  dbManager: IPosLocalDatabase | PosLocalDatabase,
  order: OrderDomain,
  items: OrderItemDomain[]
): SaveOrderResult {
  return dbManager.runTransaction((db) => {
    // 1. Load authoritative existing order
    const existing = db.prepare(`
      SELECT id, table_session_id, status, version, created_at
      FROM orders
      WHERE id = ?
    `).get(order.id) as { id: string; table_session_id: string | null; status: string; version: number; created_at: string } | undefined;

    if (!existing) {
      throw new Error(`[PosPersistence] ORDER_NOT_FOUND: Cannot replace draft for non-existent order ${order.id}`);
    }

    // 2. Eligibility checks: ONLY draft status
    if (existing.status !== 'draft') {
      throw new Error(`[PosPersistence] ORDER_NOT_EDITABLE: Order ${order.id} has status '${existing.status}', only 'draft' status may be replaced`);
    }

    // 3. KOT Boundary Check
    const existingKot = db.prepare('SELECT id FROM pos_kots WHERE order_id = ? LIMIT 1').get(order.id);
    if (existingKot) {
      throw new Error(`[PosPersistence] KOT_ALREADY_SENT: Order ${order.id} already has dispatched KOTs, draft replacement prohibited`);
    }

    // 4. Session identity stability
    if ((existing.table_session_id ?? null) !== (order.table_session_id ?? null)) {
      throw new Error(`[PosPersistence] SESSION_MISMATCH: Order ${order.id} table_session_id cannot be changed during draft replacement`);
    }

    // 5. Version Rules: exactly existing.version + 1
    const currentVersion = existing.version ?? 1;
    const expectedVersion = currentVersion + 1;
    const incomingVersion = order.version ?? expectedVersion;

    if (incomingVersion !== expectedVersion) {
      if (incomingVersion <= currentVersion) {
        throw new Error(`[PosPersistence] STALE_VERSION: Incoming version ${incomingVersion} <= current version ${currentVersion}`);
      } else {
        throw new Error(`[PosPersistence] VERSION_GAP: Incoming version ${incomingVersion} skips expected version ${expectedVersion}`);
      }
    }

    if (!items || items.length === 0) {
      throw new Error(`[PosPersistence] EMPTY_ITEMS: Order draft aggregate must contain at least one order item`);
    }

    const now = order.updated_at || new Date().toISOString();

    // 6. Delete old draft items
    db.prepare('DELETE FROM order_items WHERE order_id = ?').run(order.id);

    // 7. Insert replacement items
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
        order.id,
        item.product_id,
        item.variant_id ?? null,
        item.product_name,
        toPaise(item.unit_price),
        item.quantity,
        item.tax_rate,
        toPaise(item.discount_amount),
        toPaise(item.line_total),
        item.notes ?? null,
        item.created_at || now
      );
    }

    // 8. Update Order Financial Header and Version
    db.prepare(`
      UPDATE orders SET
        subtotal_paise = ?,
        tax_total_paise = ?,
        discount_total_paise = ?,
        delivery_charge_paise = ?,
        grand_total_paise = ?,
        version = ?,
        updated_at = ?
      WHERE id = ?
    `).run(
      toPaise(order.subtotal),
      toPaise(order.tax_total),
      toPaise(order.discount_total),
      toPaise(order.delivery_charge),
      toPaise(order.grand_total),
      incomingVersion,
      now,
      order.id
    );

    const updatedOrder: OrderDomain = {
      ...order,
      version: incomingVersion,
      updated_at: now,
    };

    // 9. Emit durable UPDATE outbox entry in the SAME transaction
    const outboxRow = insertOutboxRecord(db, {
      entityType: 'orders',
      entityId: order.id,
      operation: 'UPDATE',
      payload: {
        order: updatedOrder,
        items,
        version: incomingVersion,
      },
      createdAt: now,
    });

    return {
      order: updatedOrder,
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
    // 1. Verify and advance order status atomically
    const order = db.prepare('SELECT status FROM orders WHERE id = ?').get(kot.order_id) as { status: string } | undefined;
    if (!order) {
      throw new Error(`[PosPersistence] ORDER_NOT_FOUND: Order ${kot.order_id} does not exist for KOT dispatch`);
    }
    if (order.status === 'cancelled' || order.status === 'closed') {
      throw new Error(`[PosPersistence] ORDER_STATUS_INVALID: Cannot dispatch KOT for order ${kot.order_id} with status '${order.status}'`);
    }
    if (order.status === 'billed' || order.status === 'settled') {
      throw new Error(`[PosPersistence] ORDER_STATUS_REGRESSION: Cannot dispatch KOT for order ${kot.order_id} already in status '${order.status}'`);
    }

    const now = new Date().toISOString();
    db.prepare('UPDATE orders SET status = ?, updated_at = ? WHERE id = ?').run('kot_sent', now, kot.order_id);

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
        id, kot_id, order_item_id, product_id, variant_id, product_name, quantity, notes
      ) VALUES (
        ?, ?, ?, ?, ?, ?, ?, ?
      )
    `);

    for (const item of items) {
      itemStmt.run(
        item.id,
        item.kot_id,
        item.order_item_id ?? null,
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
 * Atomically appends new commercial order items, updates cumulative order totals,
 * allocates monotonic KOT number, creates immutable KOT snapshot for new items,
 * and emits a durable sync outbox record.
 * 
 * Enforces:
 * - Order exists and status == 'kot_sent'
 * - Active table session
 * - Non-empty new items and KOT items
 * - Idempotent replay for same KOT operation ID (kot.id)
 * - Conflict rejection for mismatched payload or conflicting item IDs
 * - Preserves existing order_items immutably
 * - Retains order.status == 'kot_sent' with unchanged order.version
 */
export function appendOrderItemsAndKotTransaction(
  dbManager: IPosLocalDatabase | PosLocalDatabase,
  order: OrderDomain,
  newItems: OrderItemDomain[],
  kot: PosKotDomain,
  kotItems: KotItemDomain[]
): AppendOrderItemsAndKotResult {
  return dbManager.runTransaction((db) => {
    // 1. Load authoritative existing order
    const existing = db.prepare(`
      SELECT id, display_number, channel, order_type, customer_id, table_session_id, status,
             subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise,
             grand_total_paise, device_id, version, created_at, updated_at
      FROM orders
      WHERE id = ?
    `).get(order.id) as {
      id: string;
      display_number: string | null;
      channel: string;
      order_type: string;
      customer_id: string | null;
      table_session_id: string | null;
      status: string;
      subtotal_paise: number;
      tax_total_paise: number;
      discount_total_paise: number;
      delivery_charge_paise: number;
      grand_total_paise: number;
      device_id: string | null;
      version: number;
      created_at: string;
      updated_at: string;
    } | undefined;

    if (!existing) {
      throw new Error(`[PosPersistence] ORDER_NOT_FOUND: Order ${order.id} does not exist for additional KOT`);
    }

    // 2. Status Eligibility Guard: ONLY 'kot_sent' allowed
    if (existing.status !== 'kot_sent') {
      throw new Error(`[PosPersistence] ORDER_STATUS_INVALID: Order ${order.id} has status '${existing.status}', only 'kot_sent' orders can receive additional items and KOT`);
    }

    // 3. Active Session Guard
    if (existing.table_session_id) {
      const session = db.prepare('SELECT session_status FROM table_sessions WHERE id = ?').get(existing.table_session_id) as { session_status: string } | undefined;
      if (!session || session.session_status !== 'open') {
        throw new Error(`[PosPersistence] SESSION_NOT_ACTIVE: Table session ${existing.table_session_id} has status '${session?.session_status || 'missing'}', must be 'open'`);
      }
    }

    // 4. Non-empty Item Guards
    if (!newItems || newItems.length === 0) {
      throw new Error(`[PosPersistence] EMPTY_ITEMS: Additional KOT requires at least one new order item`);
    }
    if (!kotItems || kotItems.length === 0) {
      throw new Error(`[PosPersistence] EMPTY_KOT_ITEMS: Additional KOT requires at least one KOT item`);
    }

    // 5. Operation Idempotency Check (Canonical Operation ID: kot.id)
    const existingKot = db.prepare('SELECT id, order_id, kot_number, device_id, status, printed_at FROM pos_kots WHERE id = ?').get(kot.id) as {
      id: string;
      order_id: string;
      kot_number: number;
      device_id: string | null;
      status: string;
      printed_at: string;
    } | undefined;

    if (existingKot) {
      if (existingKot.order_id !== order.id) {
        throw new Error(`[PosPersistence] IDEMPOTENCY_CONFLICT: KOT ID ${kot.id} belongs to order ${existingKot.order_id}, cannot replay on order ${order.id}`);
      }

      if (existingKot.kot_number !== kot.kot_number) {
        throw new Error(`[PosPersistence] IDEMPOTENCY_CONFLICT: KOT ID ${kot.id} has kot_number ${existingKot.kot_number}, retry payload has ${kot.kot_number}`);
      }

      // Verify cumulative order financial header
      if (
        existing.subtotal_paise !== toPaise(order.subtotal ?? 0) ||
        existing.tax_total_paise !== toPaise(order.tax_total ?? 0) ||
        existing.discount_total_paise !== toPaise(order.discount_total ?? 0) ||
        existing.delivery_charge_paise !== toPaise(order.delivery_charge ?? 0) ||
        existing.grand_total_paise !== toPaise(order.grand_total ?? 0)
      ) {
        throw new Error(`[PosPersistence] IDEMPOTENCY_CONFLICT: Order ${order.id} financial totals mismatch on retry for KOT ID ${kot.id}`);
      }

      if (order.table_session_id && existing.table_session_id && order.table_session_id !== existing.table_session_id) {
        throw new Error(`[PosPersistence] IDEMPOTENCY_CONFLICT: Order ${order.id} table session mismatch on retry for KOT ID ${kot.id}`);
      }

      const existingKotItems = db.prepare('SELECT id, kot_id, order_item_id, product_id, variant_id, product_name, quantity, notes FROM kot_items WHERE kot_id = ?').all(kot.id) as {
        id: string;
        kot_id: string;
        order_item_id: string | null;
        product_id: string;
        variant_id: string | null;
        product_name: string;
        quantity: number;
        notes: string | null;
      }[];

      if (existingKotItems.length !== kotItems.length) {
        throw new Error(`[PosPersistence] IDEMPOTENCY_CONFLICT: KOT ID ${kot.id} has ${existingKotItems.length} items, replay payload has ${kotItems.length}`);
      }

      for (const ki of kotItems) {
        const matched = existingKotItems.find((e) => e.id === ki.id);
        if (!matched) {
          throw new Error(`[PosPersistence] IDEMPOTENCY_CONFLICT: KOT item ${ki.id} missing on retry for KOT ID ${kot.id}`);
        }
        if (
          (matched.order_item_id ?? null) !== (ki.order_item_id ?? null) ||
          matched.product_id !== ki.product_id ||
          (matched.variant_id ?? null) !== (ki.variant_id ?? null) ||
          matched.product_name !== ki.product_name ||
          matched.quantity !== ki.quantity ||
          (matched.notes ?? null) !== (ki.notes ?? null)
        ) {
          throw new Error(`[PosPersistence] IDEMPOTENCY_CONFLICT: KOT item ${ki.id} mismatched on retry for KOT ID ${kot.id}`);
        }
      }

      for (const oi of newItems) {
        const inDb = db.prepare(`
          SELECT id, order_id, product_id, variant_id, product_name,
                 unit_price_paise, quantity, tax_rate, discount_amount_paise, line_total_paise, notes
          FROM order_items
          WHERE id = ? AND order_id = ?
        `).get(oi.id, order.id) as {
          id: string;
          order_id: string;
          product_id: string;
          variant_id: string | null;
          product_name: string;
          unit_price_paise: number;
          quantity: number;
          tax_rate: number;
          discount_amount_paise: number;
          line_total_paise: number;
          notes: string | null;
        } | undefined;

        if (!inDb) {
          throw new Error(`[PosPersistence] IDEMPOTENCY_CONFLICT: Order item ${oi.id} missing in order ${order.id} on retry for KOT ID ${kot.id}`);
        }

        const taxDiff = Math.abs(inDb.tax_rate - (oi.tax_rate ?? 5.0));
        if (
          inDb.product_id !== oi.product_id ||
          (inDb.variant_id ?? null) !== (oi.variant_id ?? null) ||
          inDb.quantity !== oi.quantity ||
          inDb.unit_price_paise !== toPaise(oi.unit_price) ||
          taxDiff > 0.001 ||
          inDb.discount_amount_paise !== toPaise(oi.discount_amount ?? 0) ||
          inDb.line_total_paise !== toPaise(oi.line_total)
        ) {
          throw new Error(`[PosPersistence] IDEMPOTENCY_CONFLICT: Order item ${oi.id} attributes mismatched on retry for KOT ID ${kot.id}`);
        }
      }

      const currentOrder = db.prepare(`
        SELECT id, display_number, channel, order_type, customer_id, table_session_id, status,
               subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise,
               grand_total_paise, device_id, version, created_at, updated_at
        FROM orders
        WHERE id = ?
      `).get(order.id) as any;

      return {
        order: {
          id: currentOrder.id,
          display_number: currentOrder.display_number ?? null,
          channel: currentOrder.channel,
          order_type: currentOrder.order_type,
          customer_id: currentOrder.customer_id ?? null,
          table_session_id: currentOrder.table_session_id ?? null,
          status: currentOrder.status,
          subtotal: toRupees(currentOrder.subtotal_paise),
          tax_total: toRupees(currentOrder.tax_total_paise),
          discount_total: toRupees(currentOrder.discount_total_paise),
          delivery_charge: toRupees(currentOrder.delivery_charge_paise),
          grand_total: toRupees(currentOrder.grand_total_paise),
          device_id: currentOrder.device_id ?? null,
          version: currentOrder.version,
          created_at: currentOrder.created_at,
          updated_at: currentOrder.updated_at,
        },
        newItems,
        kot: {
          ...kot,
          kot_number: existingKot.kot_number,
          printed_at: existingKot.printed_at,
        },
        kotItems,
        outboxEntries: [],
      };
    }

    // 6. Item ID Conflict Guard for new execution
    for (const item of newItems) {
      const existingItem = db.prepare('SELECT id FROM order_items WHERE id = ?').get(item.id);
      if (existingItem) {
        throw new Error(`[PosPersistence] ITEM_ID_CONFLICT: Order item ID ${item.id} already exists`);
      }
    }

    // 7. Monotonic KOT Number Allocation inside transaction
    const maxKotRow = db.prepare('SELECT COALESCE(MAX(kot_number), 0) AS max_kot FROM pos_kots WHERE order_id = ?').get(order.id) as { max_kot: number };
    const allocatedKotNumber = maxKotRow.max_kot + 1;

    const now = new Date().toISOString();

    // 8. Insert ONLY new order_items (preserving sent order items immutably)
    const itemStmt = db.prepare(`
      INSERT INTO order_items (
        id, order_id, product_id, variant_id, product_name, unit_price_paise,
        quantity, tax_rate, discount_amount_paise, line_total_paise, notes, created_at
      ) VALUES (
        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
      )
    `);

    for (const item of newItems) {
      itemStmt.run(
        item.id,
        order.id,
        item.product_id,
        item.variant_id ?? null,
        item.product_name,
        toPaise(item.unit_price),
        item.quantity,
        item.tax_rate ?? 5.0,
        toPaise(item.discount_amount),
        toPaise(item.line_total),
        item.notes ?? null,
        item.created_at || now
      );
    }

    // 9. Update cumulative order financial header (status remains kot_sent, version unchanged)
    db.prepare(`
      UPDATE orders SET
        subtotal_paise = ?,
        tax_total_paise = ?,
        discount_total_paise = ?,
        delivery_charge_paise = ?,
        grand_total_paise = ?,
        updated_at = ?
      WHERE id = ?
    `).run(
      toPaise(order.subtotal ?? 0),
      toPaise(order.tax_total ?? 0),
      toPaise(order.discount_total ?? 0),
      toPaise(order.delivery_charge ?? 0),
      toPaise(order.grand_total ?? 0),
      now,
      order.id
    );

    // 10. Insert KOT header
    const kotStmt = db.prepare(`
      INSERT INTO pos_kots (
        id, order_id, kot_number, device_id, status, printed_at
      ) VALUES (
        ?, ?, ?, ?, ?, ?
      )
    `);

    kotStmt.run(
      kot.id,
      order.id,
      allocatedKotNumber,
      kot.device_id ?? null,
      kot.status || 'printed',
      kot.printed_at || now
    );

    // 11. Insert KOT items
    const kotItemStmt = db.prepare(`
      INSERT INTO kot_items (
        id, kot_id, order_item_id, product_id, variant_id, product_name, quantity, notes
      ) VALUES (
        ?, ?, ?, ?, ?, ?, ?, ?
      )
    `);

    for (const ki of kotItems) {
      kotItemStmt.run(
        ki.id,
        kot.id,
        ki.order_item_id ?? null,
        ki.product_id,
        ki.variant_id ?? null,
        ki.product_name,
        ki.quantity,
        ki.notes ?? null
      );
    }

    const updatedKot: PosKotDomain = {
      ...kot,
      kot_number: allocatedKotNumber,
      printed_at: kot.printed_at || now,
    };

    const updatedOrder: OrderDomain = {
      ...order,
      status: 'kot_sent',
      version: existing.version,
      updated_at: now,
    };

    // 12. Single Atomic Outbox Row
    const outboxRow = insertOutboxRecord(db, {
      entityType: 'pos_kots',
      entityId: kot.id,
      operation: 'INSERT',
      payload: {
        kot: updatedKot,
        items: kotItems,
        orderItems: newItems,
        order: updatedOrder,
      },
      createdAt: updatedKot.printed_at,
    });

    return {
      order: updatedOrder,
      newItems,
      kot: updatedKot,
      kotItems,
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
        id, order_id, kot_id, kot_item_id, order_item_id, product_name, cancelled_qty, reason,
        authorized_by_staff_id, created_at
      ) VALUES (
        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
      )
    `);

    stmt.run(
      correction.id,
      correction.order_id,
      correction.kot_id ?? null,
      correction.kot_item_id ?? null,
      correction.order_item_id ?? null,
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
 * CHEESYOS NEXTGEN MODEL-B KOT CORRECTION TRANSACTION
 * 
 * Atomically validates:
 * - Order exists and status == 'kot_sent' (CORRECTION_ALLOWED_STATUS)
 * - Complete UUID lineage:
 *     kot_item exists
 *     kot_item.kot_id == requested kot_id
 *     kot_item.order_item_id == requested order_item_id
 *     pos_kots.order_id == requested order_id
 *     order_items.order_id == requested order_id
 * - Historical unlinked KOTs (order_item_id IS NULL) are rejected with CORRECTION_LINEAGE_UNAVAILABLE
 * - Over-correction guard: cancelled_qty > 0 AND cancelled_qty <= current order_items.quantity
 * - Operation-level idempotency:
 *     same correction.id + identical payload/projection -> IDEMPOTENT_NOOP_SUCCESS (no double deduction, no duplicate outbox)
 *     same correction.id + conflicting payload -> IDEMPOTENCY_CONFLICT
 * 
 * Atomically executes:
 * - Inserts append-only kot_corrections row (with kot_item_id and order_item_id)
 * - Updates target commercial order_items: quantity = current_qty - cancelled_qty, line_total_paise = updatedOrderItem.line_total
 *   (row preserved even if quantity reaches 0)
 * - Updates parent orders cumulative totals: subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, updated_at
 * - Emits ONE durable sync outbox record for kot_corrections INSERT containing { correction, updatedOrderItem, updatedOrder }
 * 
 * All or nothing in one SQLite transaction.
 */
export function applyKotCorrectionTransaction(
  dbManager: IPosLocalDatabase | PosLocalDatabase,
  input: ApplyKotCorrectionInput
): ApplyKotCorrectionLocalResult {
  return dbManager.runTransaction((db) => {
    const { correction, updatedOrderItem, updatedOrder } = input;

    if (!correction || !updatedOrderItem || !updatedOrder) {
      throw new Error('[PosPersistence] VALIDATION_ERROR: Missing required correction aggregate payloads');
    }

    if (correction.cancelled_qty <= 0) {
      throw new Error('[PosPersistence] INVALID_QUANTITY: cancelled_qty must be greater than 0');
    }

    if (!correction.reason || correction.reason.trim().length === 0) {
      throw new Error('[PosPersistence] VALIDATION_ERROR: Reason is required for KOT correction');
    }

    if (!correction.authorized_by_staff_id) {
      throw new Error('[PosPersistence] VALIDATION_ERROR: Staff ID is required to authorize KOT correction');
    }

    if (!correction.order_id || !correction.kot_id || !correction.kot_item_id || !correction.order_item_id) {
      throw new Error('[PosPersistence] VALIDATION_ERROR: Missing required lineage UUIDs in correction');
    }

    // 1. Operation-level Idempotency Check (Operation ID = correction.id)
    const existingCorrection = db.prepare(`
      SELECT id, order_id, kot_id, kot_item_id, order_item_id, product_name,
             cancelled_qty, reason, authorized_by_staff_id, created_at
      FROM kot_corrections
      WHERE id = ?
    `).get(correction.id) as {
      id: string;
      order_id: string;
      kot_id: string | null;
      kot_item_id: string | null;
      order_item_id: string | null;
      product_name: string;
      cancelled_qty: number;
      reason: string;
      authorized_by_staff_id: string;
      created_at: string;
    } | undefined;

    if (existingCorrection) {
      if (
        existingCorrection.order_id !== correction.order_id ||
        (existingCorrection.kot_id ?? null) !== (correction.kot_id ?? null) ||
        (existingCorrection.kot_item_id ?? null) !== (correction.kot_item_id ?? null) ||
        (existingCorrection.order_item_id ?? null) !== (correction.order_item_id ?? null) ||
        existingCorrection.cancelled_qty !== correction.cancelled_qty ||
        existingCorrection.reason !== correction.reason ||
        existingCorrection.authorized_by_staff_id !== correction.authorized_by_staff_id
      ) {
        throw new Error(`[PosPersistence] IDEMPOTENCY_CONFLICT: Correction ID ${correction.id} already exists with different payload`);
      }

      // Verify current order and order_item match projected state
      const currentItem = db.prepare(`
        SELECT id, order_id, product_id, variant_id, product_name, unit_price_paise,
               quantity, tax_rate, discount_amount_paise, line_total_paise, notes, created_at
        FROM order_items
        WHERE id = ?
      `).get(correction.order_item_id) as any;

      if (!currentItem || currentItem.quantity !== updatedOrderItem.quantity || currentItem.line_total_paise !== toPaise(updatedOrderItem.line_total ?? 0)) {
        throw new Error(`[PosPersistence] IDEMPOTENCY_CONFLICT: Order item state mismatch on correction retry`);
      }

      const currentOrder = db.prepare(`
        SELECT id, display_number, channel, order_type, customer_id, table_session_id, status,
               subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise,
               grand_total_paise, device_id, version, created_at, updated_at
        FROM orders
        WHERE id = ?
      `).get(correction.order_id) as any;

      if (!currentOrder || currentOrder.grand_total_paise !== toPaise(updatedOrder.grand_total ?? 0)) {
        throw new Error(`[PosPersistence] IDEMPOTENCY_CONFLICT: Order totals mismatch on correction retry`);
      }

      return {
        correction: {
          ...correction,
          created_at: existingCorrection.created_at,
        },
        updatedOrderItem: {
          ...updatedOrderItem,
          quantity: currentItem.quantity,
          line_total: toRupees(currentItem.line_total_paise),
        },
        updatedOrder: {
          ...updatedOrder,
          subtotal: toRupees(currentOrder.subtotal_paise),
          tax_total: toRupees(currentOrder.tax_total_paise),
          discount_total: toRupees(currentOrder.discount_total_paise),
          delivery_charge: toRupees(currentOrder.delivery_charge_paise),
          grand_total: toRupees(currentOrder.grand_total_paise),
          status: currentOrder.status,
          updated_at: currentOrder.updated_at,
        },
        outboxEntry: {
          seq: 0,
          id: '',
          entity_type: 'kot_corrections',
          entity_id: correction.id,
          operation: 'INSERT',
          payload_json: '',
          created_at: existingCorrection.created_at,
          attempt_count: 0,
          next_attempt_at: null,
          last_error: null,
        },
      };
    }

    // 2. Load and validate target Order (status gate: kot_sent only)
    const existingOrder = db.prepare(`
      SELECT id, status, subtotal_paise, tax_total_paise, discount_total_paise,
             delivery_charge_paise, grand_total_paise, version, table_session_id
      FROM orders
      WHERE id = ?
    `).get(correction.order_id) as {
      id: string;
      status: string;
      subtotal_paise: number;
      tax_total_paise: number;
      discount_total_paise: number;
      delivery_charge_paise: number;
      grand_total_paise: number;
      version: number;
      table_session_id: string | null;
    } | undefined;

    if (!existingOrder) {
      throw new Error(`[PosPersistence] ORDER_NOT_FOUND: Order ${correction.order_id} does not exist for correction`);
    }

    if (existingOrder.status !== 'kot_sent') {
      throw new Error(`[PosPersistence] ORDER_STATUS_INVALID: Order ${correction.order_id} has status '${existingOrder.status}', only 'kot_sent' orders can be corrected`);
    }

    // 3. Load and validate target Commercial Order Item
    const existingOrderItem = db.prepare(`
      SELECT id, order_id, product_id, variant_id, product_name, unit_price_paise,
             quantity, tax_rate, discount_amount_paise, line_total_paise, notes, created_at
      FROM order_items
      WHERE id = ?
    `).get(correction.order_item_id) as {
      id: string;
      order_id: string;
      product_id: string;
      variant_id: string | null;
      product_name: string;
      unit_price_paise: number;
      quantity: number;
      tax_rate: number;
      discount_amount_paise: number;
      line_total_paise: number;
      notes: string | null;
      created_at: string;
    } | undefined;

    if (!existingOrderItem) {
      throw new Error(`[PosPersistence] ORDER_ITEM_NOT_FOUND: Order item ${correction.order_item_id} does not exist`);
    }

    if (existingOrderItem.order_id !== correction.order_id) {
      throw new Error(`[PosPersistence] LINEAGE_MISMATCH: Order item ${correction.order_item_id} belongs to order ${existingOrderItem.order_id}, not requested ${correction.order_id}`);
    }

    // 4. Load and validate KOT and KOT Item Lineage
    const existingKot = db.prepare('SELECT id, order_id FROM pos_kots WHERE id = ?').get(correction.kot_id) as {
      id: string;
      order_id: string;
    } | undefined;

    if (!existingKot) {
      throw new Error(`[PosPersistence] KOT_NOT_FOUND: KOT ${correction.kot_id} does not exist`);
    }

    if (existingKot.order_id !== correction.order_id) {
      throw new Error(`[PosPersistence] LINEAGE_MISMATCH: KOT ${correction.kot_id} belongs to order ${existingKot.order_id}, not requested ${correction.order_id}`);
    }

    const existingKotItem = db.prepare(`
      SELECT id, kot_id, order_item_id, product_id, variant_id, product_name, quantity, notes
      FROM kot_items
      WHERE id = ?
    `).get(correction.kot_item_id) as {
      id: string;
      kot_id: string;
      order_item_id: string | null;
      product_id: string;
      variant_id: string | null;
      product_name: string;
      quantity: number;
      notes: string | null;
    } | undefined;

    if (!existingKotItem) {
      throw new Error(`[PosPersistence] KOT_ITEM_NOT_FOUND: KOT item ${correction.kot_item_id} does not exist`);
    }

    if (existingKotItem.kot_id !== correction.kot_id) {
      throw new Error(`[PosPersistence] LINEAGE_MISMATCH: KOT item ${correction.kot_item_id} belongs to KOT ${existingKotItem.kot_id}, not requested ${correction.kot_id}`);
    }

    if (existingKotItem.order_item_id === null || existingKotItem.order_item_id === undefined) {
      throw new Error(`[PosPersistence] CORRECTION_LINEAGE_UNAVAILABLE: Historical KOT item ${correction.kot_item_id} does not carry order_item_id`);
    }

    if (existingKotItem.order_item_id !== correction.order_item_id) {
      throw new Error(`[PosPersistence] LINEAGE_MISMATCH: KOT item ${correction.kot_item_id} links to order item ${existingKotItem.order_item_id}, not requested ${correction.order_item_id}`);
    }

    // 5. Over-Correction Protection (Current Billable Authority = order_items.quantity)
    if (correction.cancelled_qty > existingOrderItem.quantity) {
      throw new Error(`[PosPersistence] OVER_CORRECTION: Cannot cancel ${correction.cancelled_qty} units when current billable quantity is ${existingOrderItem.quantity}`);
    }

    const newQuantity = existingOrderItem.quantity - correction.cancelled_qty;
    if (updatedOrderItem.quantity !== newQuantity) {
      throw new Error(`[PosPersistence] VALIDATION_ERROR: Target order item quantity mismatch (expected ${newQuantity}, got ${updatedOrderItem.quantity})`);
    }

    const now = correction.created_at || new Date().toISOString();

    // 6. Insert Append-Only Correction Audit Event
    const correctionStmt = db.prepare(`
      INSERT INTO kot_corrections (
        id, order_id, kot_id, kot_item_id, order_item_id,
        product_name, cancelled_qty, reason, authorized_by_staff_id, created_at
      ) VALUES (
        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
      )
    `);

    correctionStmt.run(
      correction.id,
      correction.order_id,
      correction.kot_id,
      correction.kot_item_id,
      correction.order_item_id,
      correction.product_name || existingOrderItem.product_name,
      correction.cancelled_qty,
      correction.reason.trim(),
      correction.authorized_by_staff_id,
      now
    );

    // 7. Mutate Target Commercial Order Item (Preserved even if quantity = 0)
    db.prepare(`
      UPDATE order_items
      SET quantity = ?,
          line_total_paise = ?
      WHERE id = ?
    `).run(
      newQuantity,
      toPaise(updatedOrderItem.line_total),
      correction.order_item_id
    );

    // 8. Mutate Parent Order Cumulative Financial Totals
    db.prepare(`
      UPDATE orders
      SET subtotal_paise = ?,
          tax_total_paise = ?,
          discount_total_paise = ?,
          delivery_charge_paise = ?,
          grand_total_paise = ?,
          updated_at = ?
      WHERE id = ?
    `).run(
      toPaise(updatedOrder.subtotal ?? 0),
      toPaise(updatedOrder.tax_total ?? 0),
      toPaise(updatedOrder.discount_total ?? 0),
      toPaise(updatedOrder.delivery_charge ?? 0),
      toPaise(updatedOrder.grand_total ?? 0),
      now,
      correction.order_id
    );

    const resultingOrder: OrderDomain = {
      ...updatedOrder,
      status: 'kot_sent',
      version: existingOrder.version,
      updated_at: now,
    };

    const resultingItem: OrderItemDomain = {
      ...existingOrderItem,
      ...updatedOrderItem,
      quantity: newQuantity,
      unit_price: toRupees(existingOrderItem.unit_price_paise),
      discount_amount: toRupees(existingOrderItem.discount_amount_paise),
      line_total: updatedOrderItem.line_total,
    };

    const resultingCorrection: KotCorrectionDomain = {
      ...correction,
      created_at: now,
    };

    // 9. Emit ONE Durable Outbox Record in the same transaction
    const outboxRow = insertOutboxRecord(db, {
      entityType: 'kot_corrections',
      entityId: correction.id,
      operation: 'INSERT',
      payload: {
        correction: resultingCorrection,
        updatedOrderItem: resultingItem,
        updatedOrder: resultingOrder,
      },
      createdAt: now,
    });

    return {
      correction: resultingCorrection,
      updatedOrderItem: resultingItem,
      updatedOrder: resultingOrder,
      outboxEntry: outboxRow,
    };
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
    // 1. Verify and advance order status atomically
    const order = db.prepare('SELECT status, table_session_id FROM orders WHERE id = ?').get(bill.order_id) as { status: string; table_session_id: string | null } | undefined;
    if (!order) {
      throw new Error(`[PosPersistence] ORDER_NOT_FOUND: Order ${bill.order_id} does not exist for bill finalization`);
    }
    if (order.status === 'cancelled' || order.status === 'closed') {
      throw new Error(`[PosPersistence] ORDER_STATUS_INVALID: Cannot finalize bill for order ${bill.order_id} with status '${order.status}'`);
    }
    if (order.status === 'settled') {
      throw new Error(`[PosPersistence] ORDER_STATUS_REGRESSION: Cannot finalize bill for already settled order ${bill.order_id}`);
    }

    const now = bill.finalized_at || new Date().toISOString();
    db.prepare('UPDATE orders SET status = ?, updated_at = ? WHERE id = ?').run('billed', now, bill.order_id);
    if (order.table_session_id) {
      db.prepare(`UPDATE table_sessions SET session_status = 'billed' WHERE id = ? AND session_status = 'open'`).run(order.table_session_id);
      const sess = db.prepare(`SELECT id, table_id, current_order_id, guest_count, session_status, opened_at, closed_at FROM table_sessions WHERE id = ?`).get(order.table_session_id) as {
        id: string;
        table_id: string;
        current_order_id: string | null;
        guest_count: number;
        session_status: string;
        opened_at: string;
        closed_at: string | null;
      } | undefined;
      if (sess) {
        insertOutboxRecord(db, {
          entityType: 'table_sessions',
          entityId: order.table_session_id,
          operation: 'UPDATE',
          payload: {
            session: {
              id: sess.id,
              table_id: sess.table_id,
              current_order_id: sess.current_order_id ?? bill.order_id,
              guest_count: sess.guest_count,
              session_status: 'billed',
              opened_at: sess.opened_at,
              closed_at: sess.closed_at,
            },
          },
          createdAt: now,
        });
      }
    }

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

    // Verify and advance order status atomically
    const order = db.prepare('SELECT status, table_session_id FROM orders WHERE id = ?').get(authoritativeBill.order_id) as { status: string; table_session_id: string | null } | undefined;
    if (!order) {
      throw new Error(`[PosPersistence] ORDER_NOT_FOUND: Order ${authoritativeBill.order_id} does not exist for bill finalization`);
    }
    if (order.status === 'cancelled' || order.status === 'closed') {
      throw new Error(`[PosPersistence] ORDER_STATUS_INVALID: Cannot finalize bill for order ${authoritativeBill.order_id} with status '${order.status}'`);
    }
    if (order.status === 'settled') {
      throw new Error(`[PosPersistence] ORDER_STATUS_REGRESSION: Cannot finalize bill for already settled order ${authoritativeBill.order_id}`);
    }

    const now = authoritativeBill.finalized_at || new Date().toISOString();
    db.prepare('UPDATE orders SET status = ?, updated_at = ? WHERE id = ?').run('billed', now, authoritativeBill.order_id);
    if (order.table_session_id) {
      db.prepare(`UPDATE table_sessions SET session_status = 'billed' WHERE id = ? AND session_status = 'open'`).run(order.table_session_id);
      const sess = db.prepare(`SELECT id, table_id, current_order_id, guest_count, session_status, opened_at, closed_at FROM table_sessions WHERE id = ?`).get(order.table_session_id) as {
        id: string;
        table_id: string;
        current_order_id: string | null;
        guest_count: number;
        session_status: string;
        opened_at: string;
        closed_at: string | null;
      } | undefined;
      if (sess) {
        insertOutboxRecord(db, {
          entityType: 'table_sessions',
          entityId: order.table_session_id,
          operation: 'UPDATE',
          payload: {
            session: {
              id: sess.id,
              table_id: sess.table_id,
              current_order_id: sess.current_order_id ?? authoritativeBill.order_id,
              guest_count: sess.guest_count,
              session_status: 'billed',
              opened_at: sess.opened_at,
              closed_at: sess.closed_at,
            },
          },
          createdAt: now,
        });
      }
    }

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
    // 0. Operation-level Idempotency Check FIRST
    const existingPayment = db.prepare(`
      SELECT id, bill_id, order_id, payment_mode, amount_paid_paise,
             confirmed_by_staff_id, confirmed_at, notes
      FROM payments
      WHERE id = ?
    `).get(payment.id) as {
      id: string;
      bill_id: string;
      order_id: string;
      payment_mode: string;
      amount_paid_paise: number;
      confirmed_by_staff_id: string | null;
      confirmed_at: string;
      notes: string | null;
    } | undefined;

    if (existingPayment) {
      const isMatch =
        existingPayment.id === payment.id &&
        existingPayment.bill_id === payment.bill_id &&
        existingPayment.order_id === payment.order_id &&
        existingPayment.payment_mode === payment.payment_mode &&
        existingPayment.amount_paid_paise === toPaise(payment.amount_paid) &&
        (existingPayment.confirmed_by_staff_id ?? null) === (payment.confirmed_by_staff_id ?? null) &&
        existingPayment.confirmed_at === payment.confirmed_at &&
        (existingPayment.notes ?? null) === (payment.notes ?? null);

      if (!isMatch) {
        throw new Error(
          `[PosPersistence] CONTRACT_CONFLICT: Payment ID ${payment.id} already exists with different payload`
        );
      }

      // Exact match -> return idempotent success
      const existingOutbox = db.prepare(`
        SELECT seq, id, entity_type, entity_id, operation, payload_json, created_at, attempt_count, next_attempt_at, last_error
        FROM sync_outbox
        WHERE entity_type = 'payments' AND entity_id = ?
        LIMIT 1
      `).get(payment.id) as OutboxRow | undefined;

      return {
        payment: {
          ...payment,
          confirmed_by_staff_id: existingPayment.confirmed_by_staff_id,
          notes: existingPayment.notes,
          confirmed_at: existingPayment.confirmed_at,
        },
        updatedBill,
        outboxEntry: existingOutbox ?? {
          seq: 0,
          id: '',
          entity_type: 'payments',
          entity_id: payment.id,
          operation: 'INSERT',
          payload_json: '',
          created_at: existingPayment.confirmed_at,
          attempt_count: 0,
          next_attempt_at: null,
          last_error: null,
        },
      };
    }

    // 1. Verify target order exists and has status === 'billed'
    const order = db.prepare('SELECT id, status FROM orders WHERE id = ?').get(payment.order_id) as { id: string; status: string } | undefined;
    if (!order) {
      throw new Error(`[PosPersistence] ORDER_NOT_FOUND: Order ${payment.order_id} does not exist for payment`);
    }
    if (order.status !== 'billed') {
      throw new Error(`[PosPersistence] ORDER_STATUS_INVALID: Cannot record payment for order ${payment.order_id} with status '${order.status}', order must be 'billed'`);
    }

    // 2. Verify target bill exists, belongs to order, and is unpaid
    const existingBill = db.prepare(`
      SELECT id, order_id, payment_status, grand_total_paise
      FROM bills
      WHERE id = ?
    `).get(payment.bill_id) as { id: string; order_id: string; payment_status: string; grand_total_paise: number } | undefined;

    if (!existingBill) {
      throw new Error(`[PosPersistence] BILL_NOT_FOUND: Bill ${payment.bill_id} does not exist for payment`);
    }

    if (existingBill.order_id !== payment.order_id) {
      throw new Error(`[PosPersistence] BILL_ORDER_MISMATCH: Bill ${payment.bill_id} belongs to order ${existingBill.order_id}, not requested ${payment.order_id}`);
    }

    if (existingBill.payment_status !== 'unpaid') {
      throw new Error(`[PosPersistence] BILL_ALREADY_SETTLED: Bill ${payment.bill_id} has payment status '${existingBill.payment_status}', only 'unpaid' bills can be settled`);
    }

    // 3. Verify updatedBill identity consistency
    if (updatedBill.id !== payment.bill_id || updatedBill.order_id !== payment.order_id) {
      throw new Error(`[PosPersistence] BILL_ORDER_MISMATCH: updatedBill identity mismatch for bill ${payment.bill_id}`);
    }

    const now = payment.confirmed_at || new Date().toISOString();
    db.prepare('UPDATE orders SET status = ?, updated_at = ? WHERE id = ?').run('settled', now, payment.order_id);

    // 4. Insert Payment Record
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

    // 5. Update Bill Payment Status
    const billStmt = db.prepare(`
      UPDATE bills
      SET payment_status = ?
      WHERE id = ?
    `);

    billStmt.run(updatedBill.payment_status, updatedBill.id);

    // 6. Create Outbox Entry
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

/**
 * Atomically creates a new Table Session row locally.
 * Enforces:
 * - Table must exist.
 * - Table must be active.
 * - guestCount must be an integer > 0.
 * - Rejects if table already has an active session ('open' or 'billed').
 * - Emits durable table_sessions INSERT outbox entry inside the same SQLite transaction.
 */
export function openTableSessionTransaction(
  dbManager: IPosLocalDatabase | PosLocalDatabase,
  tableId: string,
  guestCount: number,
  sessionId?: string,
  openedAt?: string
): TableSessionDomain {
  return dbManager.runTransaction((db) => {
    if (!Number.isInteger(guestCount) || guestCount <= 0) {
      throw new Error(`[PosPersistence] INVALID_GUEST_COUNT: guestCount must be an integer greater than 0, received ${guestCount}`);
    }

    const table = db.prepare('SELECT id, is_active FROM pos_tables WHERE id = ?').get(tableId) as { id: string; is_active: number } | undefined;
    if (!table) {
      throw new Error(`[PosPersistence] TABLE_NOT_FOUND: Table ${tableId} does not exist`);
    }
    if (!table.is_active) {
      throw new Error(`[PosPersistence] TABLE_INACTIVE: Table ${tableId} is not active`);
    }

    const existingActive = db.prepare(`SELECT id FROM table_sessions WHERE table_id = ? AND session_status IN ('open', 'billed') LIMIT 1`).get(tableId) as { id: string } | undefined;
    if (existingActive) {
      throw new Error(`[PosPersistence] TABLE_ALREADY_OCCUPIED: Table ${tableId} already has an active session (${existingActive.id})`);
    }

    const id = sessionId || randomUUID();
    const now = openedAt || new Date().toISOString();

    db.prepare(`
      INSERT INTO table_sessions (
        id, table_id, current_order_id, guest_count, session_status, opened_at, closed_at
      ) VALUES (
        ?, ?, NULL, ?, 'open', ?, NULL
      )
    `).run(id, tableId, guestCount, now);

    const sessionDomain: TableSessionDomain = {
      id,
      table_id: tableId,
      current_order_id: null,
      guest_count: guestCount,
      session_status: 'open',
      opened_at: now,
      closed_at: null,
    };

    // Emit durable outbox entry atomically in the SAME transaction
    insertOutboxRecord(db, {
      entityType: 'table_sessions',
      entityId: id,
      operation: 'INSERT',
      payload: {
        session: sessionDomain,
      },
      createdAt: now,
    });

    return sessionDomain;
  });
}

/**
 * Atomically closes an active Table Session and marks the associated order as closed.
 * Enforces:
 * - Session exists and is active ('open' or 'billed').
 * - Order exists.
 * - Order is linked to this session.
 * - Order is settled ('settled'). Unsettled orders are strictly rejected.
 * - Atomically sets session_status='closed', closed_at=now, and orders.status='closed'.
 * - Releases table so GetTablesWithSessions naturally derives AVAILABLE.
 */
export function closeTableSessionTransaction(
  dbManager: IPosLocalDatabase | PosLocalDatabase,
  sessionId: string,
  orderId: string,
  closedAt?: string
): void {
  dbManager.runTransaction((db) => {
    const session = db.prepare(`
      SELECT id, table_id, current_order_id, guest_count, session_status, opened_at
      FROM table_sessions
      WHERE id = ?
    `).get(sessionId) as { id: string; table_id: string; current_order_id: string | null; guest_count: number; session_status: string; opened_at: string } | undefined;

    if (!session) {
      throw new Error(`[PosPersistence] SESSION_NOT_FOUND: Table session ${sessionId} does not exist`);
    }
    if (session.session_status === 'closed') {
      throw new Error(`[PosPersistence] SESSION_ALREADY_CLOSED: Table session ${sessionId} is already closed`);
    }
    if (session.session_status !== 'open' && session.session_status !== 'billed') {
      throw new Error(`[PosPersistence] SESSION_NOT_ACTIVE: Table session ${sessionId} has status '${session.session_status}', cannot close`);
    }

    const order = db.prepare(`
      SELECT id, table_session_id, status
      FROM orders
      WHERE id = ?
    `).get(orderId) as { id: string; table_session_id: string | null; status: string } | undefined;

    if (!order) {
      throw new Error(`[PosPersistence] ORDER_NOT_FOUND: Order ${orderId} does not exist`);
    }

    const isLinked = order.table_session_id === sessionId || session.current_order_id === orderId;
    if (!isLinked) {
      throw new Error(`[PosPersistence] SESSION_ORDER_MISMATCH: Order ${orderId} is not linked to session ${sessionId}`);
    }

    if (order.status !== 'settled') {
      throw new Error(`[PosPersistence] ORDER_NOT_SETTLED: Order ${orderId} has status '${order.status}', must be 'settled' before closing session`);
    }

    const now = closedAt || new Date().toISOString();

    db.prepare(`
      UPDATE table_sessions
      SET session_status = 'closed', closed_at = ?
      WHERE id = ?
    `).run(now, sessionId);

    db.prepare(`
      UPDATE orders
      SET status = 'closed', updated_at = ?
      WHERE id = ?
    `).run(now, orderId);

    // Emit durable outbox entry atomically in the SAME transaction
    insertOutboxRecord(db, {
      entityType: 'table_sessions',
      entityId: sessionId,
      operation: 'UPDATE',
      payload: {
        session: {
          id: sessionId,
          table_id: session.table_id,
          current_order_id: orderId,
          guest_count: session.guest_count ?? 1,
          session_status: 'closed',
          opened_at: session.opened_at,
          closed_at: now,
        },
        order_id: orderId,
      },
      createdAt: now,
    });
  });
}
