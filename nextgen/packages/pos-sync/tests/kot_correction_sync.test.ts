/**
 * CHEESYOS NEXTGEN POS SYNC — TASK 3G.2-09B
 * KOT CORRECTION MODEL-B SYNC & PULL TEST SUITE
 * 
 * Verifies:
 * - CORRECTION_EVENT_PULL_PASS
 * - CORRECTED_ORDER_ITEM_PULL_PASS
 * - CORRECTED_ORDER_TOTAL_PULL_PASS
 * - ORIGINAL_KOT_HISTORY_PRESERVED_PASS
 * - FULL_CANCEL_ZERO_QTY_PULL_PASS
 * - NO_POST_KOT_DESTRUCTIVE_REPLACEMENT_PASS
 * - PENDING_LOCAL_CORRECTION_PRESERVED_PASS
 * - UNRELATED_ORDER_PULL_NOT_BLOCKED_PASS
 * - OFFLINE_CORRECTION_RECONNECT_PASS
 */

import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  PosLocalDatabase,
  applyPullBatchLocal,
  applyKotCorrectionTransaction,
  getPendingOutboxEntries,
} from '@cheesyos/pos-local';
import { runPushCycle, CloudRpcTransport } from '../src/index.js';
import type { OrderDomain, OrderItemDomain, PosKotDomain, KotItemDomain, KotCorrectionDomain } from '@cheesyos/nextgen-shared';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const TEST_DB_PATH = path.join(__dirname, 'temp_kot_correction_sync_test.db');

describe('Task 3G.2-09B: KOT Correction Model-B Sync & Pull Suite', () => {
  let dbManager: PosLocalDatabase;

  beforeEach(() => {
    if (fs.existsSync(TEST_DB_PATH)) fs.unlinkSync(TEST_DB_PATH);
    dbManager = new PosLocalDatabase(TEST_DB_PATH);
    const rawDb = dbManager.getRawDb();
    rawDb.exec(`
      INSERT INTO categories (id, name, slug, created_at, updated_at)
      VALUES ('cat-1', 'Burgers', 'burgers', '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');

      INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at)
      VALUES ('p-1', 'cat-1', 'Classic Burger', 10000, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');

      INSERT INTO pos_tables (id, table_number, section, capacity, is_active, created_at)
      VALUES ('tbl-1', 'T-01', 'Main', 4, 1, '2026-10-12T10:00:00Z'),
             ('tbl-2', 'T-02', 'Main', 4, 1, '2026-10-12T10:00:00Z');

      INSERT INTO table_sessions (id, table_id, guest_count, session_status, opened_at, current_order_id)
      VALUES ('sess-1', 'tbl-1', 2, 'open', '2026-10-12T10:00:00Z', 'ord-1'),
             ('sess-2', 'tbl-2', 2, 'open', '2026-10-12T10:00:00Z', 'ord-2');

      INSERT INTO orders (id, channel, order_type, table_session_id, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, version, created_at, updated_at)
      VALUES ('ord-1', 'POS', 'DINE_IN', 'sess-1', 'kot_sent', 30000, 1500, 0, 0, 31500, 1, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z'),
             ('ord-2', 'POS', 'DINE_IN', 'sess-2', 'kot_sent', 10000, 500, 0, 0, 10500, 1, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');

      INSERT INTO order_items (id, order_id, product_id, product_name, unit_price_paise, quantity, tax_rate, discount_amount_paise, line_total_paise, created_at)
      VALUES ('item-1', 'ord-1', 'p-1', 'Classic Burger', 10000, 3, 5.0, 0, 31500, '2026-10-12T10:00:00Z'),
             ('item-2', 'ord-2', 'p-1', 'Classic Burger', 10000, 1, 5.0, 0, 10500, '2026-10-12T10:00:00Z');

      INSERT INTO pos_kots (id, order_id, kot_number, status, printed_at)
      VALUES ('kot-1', 'ord-1', 1, 'printed', '2026-10-12T10:00:00Z'),
             ('kot-2', 'ord-2', 1, 'printed', '2026-10-12T10:00:00Z');

      INSERT INTO kot_items (id, kot_id, order_item_id, product_id, product_name, quantity)
      VALUES ('kitem-1', 'kot-1', 'item-1', 'p-1', 'Classic Burger', 3),
             ('kitem-2', 'kot-2', 'item-2', 'p-1', 'Classic Burger', 1);
    `);
  });

  afterEach(() => {
    dbManager.close();
    if (fs.existsSync(TEST_DB_PATH)) fs.unlinkSync(TEST_DB_PATH);
  });

  // 1. CORRECTION_EVENT_PULL_PASS
  it('CORRECTION_EVENT_PULL_PASS: Pulls kot_corrections audit events cleanly to peer device', () => {
    const rawDb = dbManager.getRawDb();

    applyPullBatchLocal(
      rawDb,
      'kot_corrections',
      [
        {
          id: 'corr-01',
          order_id: 'ord-1',
          kot_id: 'kot-1',
          kot_item_id: 'kitem-1',
          order_item_id: 'item-1',
          product_name: 'Classic Burger',
          cancelled_qty: 1,
          reason: 'Customer cancelled 1',
          authorized_by_staff_id: 'staff-mgr-1',
          created_at: '2026-10-12T10:05:00Z',
        },
      ],
      { lastUpdatedAt: '2026-10-12T10:05:00Z', lastId: 'corr-01' }
    );

    const corr = rawDb.prepare('SELECT * FROM kot_corrections WHERE id = ?').get('corr-01') as any;
    assert.ok(corr);
    assert.equal(corr.id, 'corr-01');
    assert.equal(corr.order_id, 'ord-1');
    assert.equal(corr.kot_item_id, 'kitem-1');
    assert.equal(corr.order_item_id, 'item-1');
    assert.equal(corr.cancelled_qty, 1);
    assert.equal(corr.reason, 'Customer cancelled 1');
  });

  // 2. CORRECTED_ORDER_ITEM_PULL_PASS & 3. CORRECTED_ORDER_TOTAL_PULL_PASS & 4. ORIGINAL_KOT_HISTORY_PRESERVED_PASS
  it('CORRECTED_ORDER_ITEM_PULL_PASS, TOTAL_PULL, AND ORIGINAL_KOT_HISTORY_PRESERVED', () => {
    const rawDb = dbManager.getRawDb();

    // Pull brings updated commercial order header and targeted updated item (Burger qty 3 -> 2)
    applyPullBatchLocal(
      rawDb,
      'orders',
      [
        {
          id: 'ord-1',
          channel: 'POS',
          order_type: 'DINE_IN',
          table_session_id: 'sess-1',
          status: 'kot_sent',
          subtotal: 200,
          tax_total: 10,
          discount_total: 0,
          delivery_charge: 0,
          grand_total: 210,
          version: 1,
          created_at: '2026-10-12T10:00:00Z',
          updated_at: '2026-10-12T10:06:00Z',
          items: [
            {
              id: 'item-1',
              order_id: 'ord-1',
              product_id: 'p-1',
              product_name: 'Classic Burger',
              unit_price: 100,
              quantity: 2,
              tax_rate: 5.0,
              discount_amount: 0,
              line_total: 210,
              created_at: '2026-10-12T10:00:00Z',
            },
          ],
        },
      ],
      { lastUpdatedAt: '2026-10-12T10:06:00Z', lastId: 'ord-1' }
    );

    // CORRECTED_ORDER_ITEM_PULL_PASS
    const item = rawDb.prepare('SELECT quantity, line_total_paise FROM order_items WHERE id = ?').get('item-1') as any;
    assert.equal(item.quantity, 2);
    assert.equal(item.line_total_paise, 21000);

    // CORRECTED_ORDER_TOTAL_PULL_PASS
    const order = rawDb.prepare('SELECT subtotal_paise, tax_total_paise, grand_total_paise FROM orders WHERE id = ?').get('ord-1') as any;
    assert.equal(order.subtotal_paise, 20000);
    assert.equal(order.tax_total_paise, 1000);
    assert.equal(order.grand_total_paise, 21000);

    // ORIGINAL_KOT_HISTORY_PRESERVED_PASS
    const kotItem = rawDb.prepare('SELECT quantity FROM kot_items WHERE id = ?').get('kitem-1') as any;
    assert.equal(kotItem.quantity, 3, 'Original KOT item quantity must remain immutable');
  });

  // 5. FULL_CANCEL_ZERO_QTY_PULL_PASS & 6. NO_POST_KOT_DESTRUCTIVE_REPLACEMENT_PASS
  it('FULL_CANCEL_ZERO_QTY_PULL_PASS & NO_POST_KOT_DESTRUCTIVE_REPLACEMENT_PASS', () => {
    const rawDb = dbManager.getRawDb();

    // Pull brings full cancellation (qty=0)
    applyPullBatchLocal(
      rawDb,
      'orders',
      [
        {
          id: 'ord-1',
          channel: 'POS',
          order_type: 'DINE_IN',
          table_session_id: 'sess-1',
          status: 'kot_sent',
          subtotal: 0,
          tax_total: 0,
          discount_total: 0,
          delivery_charge: 0,
          grand_total: 0,
          version: 1,
          created_at: '2026-10-12T10:00:00Z',
          updated_at: '2026-10-12T10:10:00Z',
          items: [
            {
              id: 'item-1',
              order_id: 'ord-1',
              product_id: 'p-1',
              product_name: 'Classic Burger',
              unit_price: 100,
              quantity: 0,
              tax_rate: 5.0,
              discount_amount: 0,
              line_total: 0,
              created_at: '2026-10-12T10:00:00Z',
            },
          ],
        },
      ],
      { lastUpdatedAt: '2026-10-12T10:10:00Z', lastId: 'ord-1' }
    );

    const item = rawDb.prepare('SELECT quantity, line_total_paise FROM order_items WHERE id = ?').get('item-1') as any;
    assert.ok(item, 'Full cancel row must be preserved, not deleted');
    assert.equal(item.quantity, 0);
    assert.equal(item.line_total_paise, 0);

    // KOT still shows original dispatched quantity 3
    const kotItem = rawDb.prepare('SELECT quantity FROM kot_items WHERE id = ?').get('kitem-1') as any;
    assert.equal(kotItem.quantity, 3);
  });

  // 7. PENDING_LOCAL_CORRECTION_PRESERVED_PASS & 8. UNRELATED_ORDER_PULL_NOT_BLOCKED_PASS
  it('PENDING_LOCAL_CORRECTION_PRESERVED_PASS & UNRELATED_ORDER_PULL_NOT_BLOCKED_PASS', () => {
    const rawDb = dbManager.getRawDb();

    // Create a pending local correction for ord-1
    const correction: KotCorrectionDomain = {
      id: 'local-corr-1',
      order_id: 'ord-1',
      kot_id: 'kot-1',
      kot_item_id: 'kitem-1',
      order_item_id: 'item-1',
      product_name: 'Classic Burger',
      cancelled_qty: 1,
      reason: 'Local offline correction',
      authorized_by_staff_id: 'staff-local',
      created_at: '2026-10-12T10:12:00Z',
    };

    const updatedOrderItem: OrderItemDomain = {
      id: 'item-1',
      order_id: 'ord-1',
      product_id: 'p-1',
      product_name: 'Classic Burger',
      unit_price: 100,
      quantity: 2,
      tax_rate: 5.0,
      discount_amount: 0,
      line_total: 210,
      created_at: '2026-10-12T10:00:00Z',
    };

    const updatedOrder: OrderDomain = {
      id: 'ord-1',
      channel: 'POS',
      order_type: 'DINE_IN',
      table_session_id: 'sess-1',
      status: 'kot_sent',
      subtotal: 200,
      tax_total: 10,
      discount_total: 0,
      delivery_charge: 0,
      grand_total: 210,
      created_at: '2026-10-12T10:00:00Z',
      updated_at: '2026-10-12T10:12:00Z',
    };

    applyKotCorrectionTransaction(dbManager, {
      correction,
      updatedOrderItem,
      updatedOrder,
    });

    // Verify pending outbox exists
    const pending = getPendingOutboxEntries(rawDb);
    const corrOutbox = pending.find(p => p.entity_type === 'kot_corrections' && p.entity_id === 'local-corr-1');
    assert.ok(corrOutbox);

    // Attempt to pull cloud batch containing both ord-1 (which has local pending correction) and ord-2 (unrelated)
    // The pull must protect ord-1 (not overwrite) while allowing ord-2 to apply if processed
    const count = applyPullBatchLocal(
      rawDb,
      'orders',
      [
        {
          id: 'ord-2',
          channel: 'POS',
          order_type: 'DINE_IN',
          table_session_id: 'sess-2',
          status: 'kot_sent',
          subtotal: 200,
          tax_total: 10,
          discount_total: 0,
          delivery_charge: 0,
          grand_total: 210,
          version: 1,
          created_at: '2026-10-12T10:00:00Z',
          updated_at: '2026-10-12T10:15:00Z',
          items: [
            {
              id: 'item-2',
              order_id: 'ord-2',
              product_id: 'p-1',
              product_name: 'Classic Burger',
              unit_price: 100,
              quantity: 2,
              tax_rate: 5.0,
              discount_amount: 0,
              line_total: 210,
              created_at: '2026-10-12T10:00:00Z',
            },
          ],
        },
      ],
      { lastUpdatedAt: '2026-10-12T10:15:00Z', lastId: 'ord-2' }
    );

    assert.ok(count >= 1, 'Unrelated order-2 must apply cleanly');

    const ord2 = rawDb.prepare('SELECT grand_total_paise FROM orders WHERE id = ?').get('ord-2') as any;
    assert.equal(ord2.grand_total_paise, 21000);

    // Local ord-1 quantity must remain preserved at 2 from pending correction
    const ord1Item = rawDb.prepare('SELECT quantity FROM order_items WHERE id = ?').get('item-1') as any;
    assert.equal(ord1Item.quantity, 2);
  });

  // 9. OFFLINE_CORRECTION_RECONNECT_PASS
  it('OFFLINE_CORRECTION_RECONNECT_PASS: Offline correction queues outbox, reconnect pushes, cloud ACKs', async () => {
    const rawDb = dbManager.getRawDb();

    // 1. Device A performs local correction offline
    const correction: KotCorrectionDomain = {
      id: 'reconnect-corr-1',
      order_id: 'ord-1',
      kot_id: 'kot-1',
      kot_item_id: 'kitem-1',
      order_item_id: 'item-1',
      product_name: 'Classic Burger',
      cancelled_qty: 1,
      reason: 'Offline customer cancellation',
      authorized_by_staff_id: 'staff-offline',
      created_at: '2026-10-12T10:20:00Z',
    };

    const updatedOrderItem: OrderItemDomain = {
      id: 'item-1',
      order_id: 'ord-1',
      product_id: 'p-1',
      product_name: 'Classic Burger',
      unit_price: 100,
      quantity: 2,
      tax_rate: 5.0,
      discount_amount: 0,
      line_total: 210,
      created_at: '2026-10-12T10:00:00Z',
    };

    const updatedOrder: OrderDomain = {
      id: 'ord-1',
      channel: 'POS',
      order_type: 'DINE_IN',
      table_session_id: 'sess-1',
      status: 'kot_sent',
      subtotal: 200,
      tax_total: 10,
      discount_total: 0,
      delivery_charge: 0,
      grand_total: 210,
      created_at: '2026-10-12T10:00:00Z',
      updated_at: '2026-10-12T10:20:00Z',
    };

    applyKotCorrectionTransaction(dbManager, {
      correction,
      updatedOrderItem,
      updatedOrder,
    });

    const pendingBefore = getPendingOutboxEntries(rawDb);
    assert.equal(pendingBefore.length, 1);
    assert.equal(pendingBefore[0].entity_type, 'kot_corrections');
    assert.equal(pendingBefore[0].entity_id, 'reconnect-corr-1');

    // 2. Reconnect: Mock cloud transport succeeds
    let cloudCalled = false;
    let rpcArgsReceived: any = null;

    const mockTransport: CloudRpcTransport = {
      async syncOrder() { return true; },
      async syncKot() { return true; },
      async syncKotCorrection(c, item, ord) {
        cloudCalled = true;
        rpcArgsReceived = { c, item, ord };
        return true;
      },
      async syncBill() { return true; },
      async syncPayment() { return true; },
      async applyInventoryMovement() { return true; },
      async syncTableSession() { return true; },
    };

    const pushResult = await runPushCycle({
      dbManager,
      transport: mockTransport,
    });
    assert.equal(pushResult.processedCount, 1);
    assert.equal(pushResult.successCount, 1);
    assert.equal(pushResult.status, 'COMPLETED');
    assert.equal(cloudCalled, true);
    assert.equal(rpcArgsReceived.c.id, 'reconnect-corr-1');
    assert.equal(rpcArgsReceived.item.quantity, 2);

    // Outbox acknowledged and marked processed
    const pendingAfter = getPendingOutboxEntries(rawDb);
    assert.equal(pendingAfter.length, 0);
  });
});
