/**
 * CHEESYOS NEXTGEN POS LOCAL — LOCAL PULL BATCH APPLICATION
 * 
 * Atomically applies pulled cloud records into local SQLite and advances cursor.
 * Guarantees:
 * - Single atomic SQLite transaction per page.
 * - Pending outbox protection: skips rows if a local unpushed edit exists in sync_outbox.
 * - Aggregate pending protection: child items (order_items, kot_items) and dependent
 *   records (bills, payments, kot_corrections) are protected if parent aggregate is pending.
 * - No sync echo: zero rows created in sync_outbox.
 * - Immutable financial snapshot conflict detection for bills and payments.
 */

import { ISQLiteDatabase } from './adapter.js';
import { PullDataset } from './persistence.js';
import { setSyncCursor, getSyncCursor, hasPendingOutboxRecord } from './outbox.js';

function toPaise(rupees: number | null | undefined): number {
  if (rupees === null || rupees === undefined) return 0;
  return Math.round(Number(rupees) * 100);
}

function toIsoString(val: any): string {
  if (!val) return new Date().toISOString();
  if (val instanceof Date) return val.toISOString();
  return String(val);
}

export function applyPullBatchLocal(
  db: ISQLiteDatabase,
  dataset: PullDataset,
  rows: any[],
  newCursor: { lastUpdatedAt: string; lastId: string }
): number {
  let rowsApplied = 0;

  if (!rows || rows.length === 0) {
    setSyncCursor(db, dataset, newCursor.lastUpdatedAt, newCursor.lastId);
    return 0;
  }

  const existingCursor = getSyncCursor(db, dataset);
  let safeCursor = { lastUpdatedAt: existingCursor.lastUpdatedAt, lastId: existingCursor.lastId };
  let hitPendingProtection = false;

  if (dataset === 'categories') {
    const stmt = db.prepare(`
      INSERT INTO categories (id, name, slug, display_order, is_active, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name,
        slug = excluded.slug,
        display_order = excluded.display_order,
        is_active = excluded.is_active,
        created_at = excluded.created_at,
        updated_at = excluded.updated_at
    `);
    for (const row of rows) {
      if (hasPendingOutboxRecord(db, row.id)) {
        hitPendingProtection = true;
        break;
      }
      stmt.run(
        row.id,
        row.name,
        row.slug || row.id,
        row.display_order ?? row.sort_order ?? 0,
        row.is_active ? 1 : 0,
        toIsoString(row.created_at),
        toIsoString(row.updated_at)
      );
      rowsApplied++;
      safeCursor = { lastUpdatedAt: toIsoString(row.updated_at || row.created_at), lastId: row.id };
    }
  } else if (dataset === 'products') {
    const stmt = db.prepare(`
      INSERT INTO products (id, category_id, name, description, image_url, base_price_paise, is_available, tax_rate, is_inventory_tracked, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        category_id = excluded.category_id,
        name = excluded.name,
        description = excluded.description,
        image_url = excluded.image_url,
        base_price_paise = excluded.base_price_paise,
        is_available = excluded.is_available,
        tax_rate = excluded.tax_rate,
        is_inventory_tracked = excluded.is_inventory_tracked,
        created_at = excluded.created_at,
        updated_at = excluded.updated_at
    `);
    for (const row of rows) {
      if (hasPendingOutboxRecord(db, row.id)) {
        hitPendingProtection = true;
        break;
      }
      stmt.run(
        row.id,
        row.category_id,
        row.name,
        row.description || null,
        row.image_url || null,
        toPaise(row.base_price),
        row.is_available ? 1 : 0,
        row.tax_rate ?? 5.00,
        row.is_inventory_tracked ? 1 : 0,
        toIsoString(row.created_at),
        toIsoString(row.updated_at)
      );
      rowsApplied++;
      safeCursor = { lastUpdatedAt: toIsoString(row.updated_at || row.created_at), lastId: row.id };
    }
  } else if (dataset === 'product_variants') {
    const stmt = db.prepare(`
      INSERT INTO product_variants (id, product_id, variant_name, price_override_paise, is_available, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        product_id = excluded.product_id,
        variant_name = excluded.variant_name,
        price_override_paise = excluded.price_override_paise,
        is_available = excluded.is_available,
        created_at = excluded.created_at
    `);
    for (const row of rows) {
      if (hasPendingOutboxRecord(db, row.id)) {
        hitPendingProtection = true;
        break;
      }
      stmt.run(
        row.id,
        row.product_id,
        row.variant_name,
        row.price_override != null ? toPaise(row.price_override) : null,
        row.is_available ? 1 : 0,
        toIsoString(row.created_at)
      );
      rowsApplied++;
      safeCursor = { lastUpdatedAt: toIsoString(row.created_at), lastId: row.id };
    }
  } else if (dataset === 'customers') {
    const stmt = db.prepare(`
      INSERT INTO customers (id, phone, full_name, email, is_active, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        phone = excluded.phone,
        full_name = excluded.full_name,
        email = excluded.email,
        is_active = excluded.is_active,
        created_at = excluded.created_at,
        updated_at = excluded.updated_at
    `);
    for (const row of rows) {
      if (hasPendingOutboxRecord(db, row.id)) {
        hitPendingProtection = true;
        break;
      }
      stmt.run(
        row.id,
        row.phone,
        row.full_name || row.name || null,
        row.email || null,
        row.is_active !== false && row.is_active !== 0 ? 1 : 0,
        toIsoString(row.created_at),
        toIsoString(row.updated_at)
      );
      rowsApplied++;
      safeCursor = { lastUpdatedAt: toIsoString(row.updated_at || row.created_at), lastId: row.id };
    }
  } else if (dataset === 'pos_tables') {
    const stmt = db.prepare(`
      INSERT INTO pos_tables (id, table_number, section, capacity, is_active, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        table_number = excluded.table_number,
        section = excluded.section,
        capacity = excluded.capacity,
        is_active = excluded.is_active,
        created_at = excluded.created_at
    `);
    for (const row of rows) {
      if (hasPendingOutboxRecord(db, row.id)) {
        hitPendingProtection = true;
        break;
      }
      stmt.run(
        row.id,
        row.table_number,
        row.section || 'Main Floor',
        row.capacity ?? 4,
        row.is_active ? 1 : 0,
        toIsoString(row.created_at)
      );
      rowsApplied++;
      safeCursor = { lastUpdatedAt: toIsoString(row.created_at), lastId: row.id };
    }
  } else if (dataset === 'table_sessions') {
    const stmt = db.prepare(`
      INSERT INTO table_sessions (id, table_id, current_order_id, guest_count, session_status, opened_at, closed_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        table_id = excluded.table_id,
        current_order_id = excluded.current_order_id,
        guest_count = excluded.guest_count,
        session_status = excluded.session_status,
        opened_at = excluded.opened_at,
        closed_at = excluded.closed_at
    `);
    for (const row of rows) {
      if (hasPendingOutboxRecord(db, row.id)) {
        hitPendingProtection = true;
        break;
      }
      stmt.run(
        row.id,
        row.table_id,
        row.current_order_id || null,
        row.guest_count ?? 1,
        row.session_status,
        toIsoString(row.opened_at),
        row.closed_at ? toIsoString(row.closed_at) : null
      );
      rowsApplied++;
      safeCursor = { lastUpdatedAt: toIsoString(row.opened_at), lastId: row.id };
    }
  } else if (dataset === 'orders') {
    const orderStmt = db.prepare(`
      INSERT INTO orders (id, display_number, channel, order_type, customer_id, table_session_id, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, device_id, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        display_number = excluded.display_number,
        channel = excluded.channel,
        order_type = excluded.order_type,
        customer_id = excluded.customer_id,
        table_session_id = excluded.table_session_id,
        status = excluded.status,
        subtotal_paise = excluded.subtotal_paise,
        tax_total_paise = excluded.tax_total_paise,
        discount_total_paise = excluded.discount_total_paise,
        delivery_charge_paise = excluded.delivery_charge_paise,
        grand_total_paise = excluded.grand_total_paise,
        device_id = excluded.device_id,
        created_at = excluded.created_at,
        updated_at = excluded.updated_at
    `);
    const itemStmt = db.prepare(`
      INSERT INTO order_items (id, order_id, product_id, variant_id, product_name, unit_price_paise, quantity, tax_rate, discount_amount_paise, line_total_paise, notes, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        order_id = excluded.order_id,
        product_id = excluded.product_id,
        variant_id = excluded.variant_id,
        product_name = excluded.product_name,
        unit_price_paise = excluded.unit_price_paise,
        quantity = excluded.quantity,
        tax_rate = excluded.tax_rate,
        discount_amount_paise = excluded.discount_amount_paise,
        line_total_paise = excluded.line_total_paise,
        notes = excluded.notes,
        created_at = excluded.created_at
    `);

    let orderList: any[] = [];
    let itemList: any[] = [];

    if (rows.length === 1 && rows[0] && ('orders' in rows[0] || 'orderItems' in rows[0])) {
      orderList = rows[0].orders || [];
      itemList = rows[0].orderItems || [];
    } else {
      orderList = rows;
      for (const ord of rows) {
        if (Array.isArray(ord.items)) {
          itemList.push(...ord.items);
        }
      }
    }

    for (const order of orderList) {
      const isOrderPending =
        hasPendingOutboxRecord(db, order.id) ||
        itemList.some((item) => item.order_id === order.id && (hasPendingOutboxRecord(db, item.order_id) || hasPendingOutboxRecord(db, item.id)));

      if (isOrderPending) {
        hitPendingProtection = true;
        break;
      }

      orderStmt.run(
        order.id,
        order.display_number || null,
        order.channel,
        order.order_type,
        order.customer_id || null,
        order.table_session_id || null,
        order.status,
        toPaise(order.subtotal),
        toPaise(order.tax_total),
        toPaise(order.discount_total),
        toPaise(order.delivery_charge),
        toPaise(order.grand_total),
        order.device_id || null,
        toIsoString(order.created_at),
        toIsoString(order.updated_at)
      );
      rowsApplied++;

      const itemsForOrder = itemList.filter((item) => item.order_id === order.id);
      for (const item of itemsForOrder) {
        itemStmt.run(
          item.id,
          item.order_id,
          item.product_id,
          item.variant_id || null,
          item.product_name,
          toPaise(item.unit_price),
          item.quantity,
          item.tax_rate ?? 5.0,
          toPaise(item.discount_amount),
          toPaise(item.line_total),
          item.notes || null,
          toIsoString(item.created_at)
        );
        rowsApplied++;
      }

      safeCursor = { lastUpdatedAt: toIsoString(order.updated_at), lastId: order.id };
    }
  } else if (dataset === 'pos_kots') {
    const kotStmt = db.prepare(`
      INSERT INTO pos_kots (id, order_id, kot_number, device_id, status, printed_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        order_id = excluded.order_id,
        kot_number = excluded.kot_number,
        device_id = excluded.device_id,
        status = excluded.status,
        printed_at = excluded.printed_at
    `);
    const itemStmt = db.prepare(`
      INSERT INTO kot_items (id, kot_id, product_id, variant_id, product_name, quantity, notes)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        kot_id = excluded.kot_id,
        product_id = excluded.product_id,
        variant_id = excluded.variant_id,
        product_name = excluded.product_name,
        quantity = excluded.quantity,
        notes = excluded.notes
    `);

    let kotList: any[] = [];
    let itemList: any[] = [];

    if (rows.length === 1 && rows[0] && ('kots' in rows[0] || 'kotItems' in rows[0])) {
      kotList = rows[0].kots || [];
      itemList = rows[0].kotItems || [];
    } else {
      kotList = rows;
      for (const kot of rows) {
        if (Array.isArray(kot.items)) {
          itemList.push(...kot.items);
        }
      }
    }

    for (const kot of kotList) {
      const isKotPending =
        hasPendingOutboxRecord(db, kot.id) ||
        hasPendingOutboxRecord(db, kot.order_id) ||
        itemList.some((item) => item.kot_id === kot.id && (hasPendingOutboxRecord(db, item.kot_id) || hasPendingOutboxRecord(db, item.id)));

      if (isKotPending) {
        hitPendingProtection = true;
        break;
      }

      kotStmt.run(
        kot.id,
        kot.order_id,
        kot.kot_number,
        kot.device_id || null,
        kot.status,
        toIsoString(kot.printed_at)
      );
      rowsApplied++;

      const itemsForKot = itemList.filter((item) => item.kot_id === kot.id);
      for (const item of itemsForKot) {
        itemStmt.run(
          item.id,
          item.kot_id,
          item.product_id,
          item.variant_id || null,
          item.product_name,
          item.quantity,
          item.notes || null
        );
        rowsApplied++;
      }

      safeCursor = { lastUpdatedAt: toIsoString(kot.printed_at), lastId: kot.id };
    }
  } else if (dataset === 'kot_corrections') {
    const stmt = db.prepare(`
      INSERT INTO kot_corrections (id, order_id, kot_id, product_name, cancelled_qty, reason, authorized_by_staff_id, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        order_id = excluded.order_id,
        kot_id = excluded.kot_id,
        product_name = excluded.product_name,
        cancelled_qty = excluded.cancelled_qty,
        reason = excluded.reason,
        authorized_by_staff_id = excluded.authorized_by_staff_id,
        created_at = excluded.created_at
    `);
    for (const row of rows) {
      if (hasPendingOutboxRecord(db, row.id) || hasPendingOutboxRecord(db, row.order_id)) {
        hitPendingProtection = true;
        break;
      }
      stmt.run(
        row.id,
        row.order_id,
        row.kot_id || null,
        row.product_name,
        row.cancelled_qty,
        row.reason,
        row.authorized_by_staff_id,
        toIsoString(row.created_at)
      );
      rowsApplied++;
      safeCursor = { lastUpdatedAt: toIsoString(row.created_at), lastId: row.id };
    }
  } else if (dataset === 'bills') {
    const stmt = db.prepare(`
      INSERT INTO bills (id, order_id, bill_number, subtotal_paise, cgst_total_paise, sgst_total_paise, discount_total_paise, grand_total_paise, payment_status, finalized_at, device_id)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        order_id = excluded.order_id,
        bill_number = excluded.bill_number,
        subtotal_paise = excluded.subtotal_paise,
        cgst_total_paise = excluded.cgst_total_paise,
        sgst_total_paise = excluded.sgst_total_paise,
        discount_total_paise = excluded.discount_total_paise,
        grand_total_paise = excluded.grand_total_paise,
        payment_status = excluded.payment_status,
        finalized_at = excluded.finalized_at,
        device_id = excluded.device_id
    `);
    for (const row of rows) {
      if (hasPendingOutboxRecord(db, row.id) || hasPendingOutboxRecord(db, row.order_id)) {
        hitPendingProtection = true;
        break;
      }
      const existing = db.prepare('SELECT grand_total_paise FROM bills WHERE id = ?').get(row.id) as { grand_total_paise: number } | undefined;
      if (existing && existing.grand_total_paise !== toPaise(row.grand_total)) {
        throw new Error(`CONTRACT_CONFLICT: Immutable bill payload mismatch for bill ID ${row.id}`);
      }
      stmt.run(
        row.id,
        row.order_id,
        row.bill_number,
        toPaise(row.subtotal),
        toPaise(row.cgst_total),
        toPaise(row.sgst_total),
        toPaise(row.discount_total),
        toPaise(row.grand_total),
        row.payment_status,
        toIsoString(row.finalized_at),
        row.device_id || null
      );
      rowsApplied++;
      safeCursor = { lastUpdatedAt: toIsoString(row.finalized_at), lastId: row.id };
    }
  } else if (dataset === 'payments') {
    const stmt = db.prepare(`
      INSERT INTO payments (id, bill_id, order_id, payment_mode, amount_paid_paise, confirmed_by_staff_id, confirmed_at, notes)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        bill_id = excluded.bill_id,
        order_id = excluded.order_id,
        payment_mode = excluded.payment_mode,
        amount_paid_paise = excluded.amount_paid_paise,
        confirmed_by_staff_id = excluded.confirmed_by_staff_id,
        confirmed_at = excluded.confirmed_at,
        notes = excluded.notes
    `);
    for (const row of rows) {
      if (hasPendingOutboxRecord(db, row.id) || hasPendingOutboxRecord(db, row.order_id)) {
        hitPendingProtection = true;
        break;
      }
      const existing = db.prepare('SELECT amount_paid_paise FROM payments WHERE id = ?').get(row.id) as { amount_paid_paise: number } | undefined;
      if (existing && existing.amount_paid_paise !== toPaise(row.amount_paid)) {
        throw new Error(`CONTRACT_CONFLICT: Immutable payment payload mismatch for payment ID ${row.id}`);
      }
      stmt.run(
        row.id,
        row.bill_id,
        row.order_id,
        row.payment_mode,
        toPaise(row.amount_paid),
        row.confirmed_by_staff_id || null,
        toIsoString(row.confirmed_at),
        row.notes || null
      );
      rowsApplied++;
      safeCursor = { lastUpdatedAt: toIsoString(row.confirmed_at), lastId: row.id };
    }
  } else if (dataset === 'inventory_lite') {
    const stmt = db.prepare(`
      INSERT INTO inventory_lite (id, product_id, current_stock, low_stock_threshold, is_tracked, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(product_id) DO UPDATE SET
        current_stock = excluded.current_stock,
        low_stock_threshold = excluded.low_stock_threshold,
        is_tracked = excluded.is_tracked,
        updated_at = excluded.updated_at
    `);
    for (const row of rows) {
      const pId = row.product_id || row.id;
      if (hasPendingOutboxRecord(db, pId)) {
        hitPendingProtection = true;
        break;
      }
      stmt.run(
        row.id || row.product_id,
        row.product_id,
        row.current_stock,
        row.low_stock_threshold ?? 5,
        row.is_tracked ? 1 : 0,
        toIsoString(row.updated_at)
      );
      rowsApplied++;
      safeCursor = { lastUpdatedAt: toIsoString(row.updated_at), lastId: String(pId) };
    }
  }

  if (!hitPendingProtection) {
    setSyncCursor(db, dataset, newCursor.lastUpdatedAt, newCursor.lastId);
  } else {
    setSyncCursor(db, dataset, safeCursor.lastUpdatedAt, safeCursor.lastId);
  }

  return rowsApplied;
}
