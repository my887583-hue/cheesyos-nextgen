/**
 * CHEESYOS NEXTGEN POS SYNC — TASK 3G.2-08A
 * ATOMIC ADDITIONAL KOT CONTRACT SYNC TEST SUITE
 * Push, Pull, Pending Protection, and Offline Reconnect
 */

import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  PosLocalDatabase,
  appendOrderItemsAndKotTransaction,
  applyPullBatchLocal,
  getPendingOutboxEntries,
} from '@cheesyos/pos-local';
import { runPushCycle, CloudRpcTransport } from '../src/index.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const TEST_DB_PATH = path.join(__dirname, 'temp_additional_kot_sync_test.db');

describe('Task 3G.2-08A: Atomic Additional KOT Sync & Pull Suite', () => {
  let dbManager: PosLocalDatabase;

  beforeEach(() => {
    if (fs.existsSync(TEST_DB_PATH)) fs.unlinkSync(TEST_DB_PATH);
    dbManager = new PosLocalDatabase(TEST_DB_PATH);
    const rawDb = dbManager.getRawDb();
    rawDb.exec(`
      INSERT INTO categories (id, name, slug, created_at, updated_at)
      VALUES ('cat-1', 'Pizzas', 'pizzas', '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');

      INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at)
      VALUES ('p-1', 'cat-1', 'Margherita', 10000, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');

      INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at)
      VALUES ('p-2', 'cat-1', 'Farmhouse', 20000, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');

      INSERT INTO pos_tables (id, table_number, section, capacity, is_active, created_at)
      VALUES ('tbl-1', 'T-01', 'Main', 4, 1, '2026-10-12T10:00:00Z');

      INSERT INTO table_sessions (id, table_id, guest_count, session_status, opened_at, current_order_id)
      VALUES ('sess-1', 'tbl-1', 2, 'open', '2026-10-12T10:00:00Z', 'ord-1');

      INSERT INTO orders (id, channel, order_type, table_session_id, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, version, created_at, updated_at)
      VALUES ('ord-1', 'POS', 'DINE_IN', 'sess-1', 'kot_sent', 10000, 500, 0, 0, 10500, 1, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');

      INSERT INTO order_items (id, order_id, product_id, product_name, unit_price_paise, quantity, tax_rate, discount_amount_paise, line_total_paise, created_at)
      VALUES ('item-1', 'ord-1', 'p-1', 'Margherita', 10000, 1, 5.0, 0, 10000, '2026-10-12T10:00:00Z');

      INSERT INTO pos_kots (id, order_id, kot_number, status, printed_at)
      VALUES ('kot-1', 'ord-1', 1, 'printed', '2026-10-12T10:00:00Z');

      INSERT INTO kot_items (id, kot_id, product_id, product_name, quantity)
      VALUES ('kitem-1', 'kot-1', 'p-1', 'Margherita', 1);
    `);
  });

  afterEach(() => {
    dbManager.close();
    if (fs.existsSync(TEST_DB_PATH)) fs.unlinkSync(TEST_DB_PATH);
  });

  it('POST_KOT_PULL_APPENDS_NEW_ITEMS_PASS & POST_KOT_PULL_EXISTING_ITEMS_PRESERVED_PASS', () => {
    const rawDb = dbManager.getRawDb();

    // Pull brings updated cumulative order header and newly appended order item
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
          subtotal: 300,
          tax_total: 15,
          discount_total: 0,
          delivery_charge: 0,
          grand_total: 315,
          version: 1,
          created_at: '2026-10-12T10:00:00Z',
          updated_at: '2026-10-12T10:15:00Z',
          items: [
            {
              id: 'item-2',
              order_id: 'ord-1',
              product_id: 'p-2',
              product_name: 'Farmhouse',
              unit_price: 200,
              quantity: 1,
              tax_rate: 5,
              discount_amount: 0,
              line_total: 200,
              created_at: '2026-10-12T10:15:00Z',
            },
          ],
        },
      ],
      { lastUpdatedAt: '2026-10-12T10:15:00Z', lastId: 'ord-1' }
    );

    // Verify order totals updated
    const order = rawDb.prepare('SELECT subtotal_paise, grand_total_paise, status FROM orders WHERE id = ?').get('ord-1') as {
      subtotal_paise: number;
      grand_total_paise: number;
      status: string;
    };
    assert.equal(order.subtotal_paise, 30000);
    assert.equal(order.grand_total_paise, 31500);
    assert.equal(order.status, 'kot_sent');

    // Verify both item-1 and item-2 exist (append-only)
    const items = rawDb.prepare('SELECT id, product_name, quantity FROM order_items WHERE order_id = ? ORDER BY id ASC').all('ord-1') as {
      id: string;
      product_name: string;
      quantity: number;
    }[];
    assert.equal(items.length, 2);
    assert.equal(items[0].id, 'item-1');
    assert.equal(items[0].quantity, 1);
    assert.equal(items[1].id, 'item-2');
    assert.equal(items[1].quantity, 1);
  });

  it('POST_KOT_PULL_NO_DESTRUCTIVE_DELETE_PASS: Missing cloud item does not delete local sent item', () => {
    const rawDb = dbManager.getRawDb();

    // Pull brings order without item-1 in its payload
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
          subtotal: 100,
          grand_total: 105,
          version: 1,
          created_at: '2026-10-12T10:00:00Z',
          updated_at: '2026-10-12T10:00:00Z',
          items: [],
        },
      ],
      { lastUpdatedAt: '2026-10-12T10:00:00Z', lastId: 'ord-1' }
    );

    // item-1 was NOT deleted
    const items = rawDb.prepare('SELECT id FROM order_items WHERE order_id = ?').all('ord-1') as { id: string }[];
    assert.equal(items.length, 1);
    assert.equal(items[0].id, 'item-1');
  });

  it('POST_KOT_PULL_NEW_KOT_PASS & POST_KOT_PULL_KOT_ITEMS_PASS', () => {
    const rawDb = dbManager.getRawDb();

    // Pull brings KOT #2 and its items
    applyPullBatchLocal(
      rawDb,
      'pos_kots',
      [
        {
          id: 'kot-2',
          order_id: 'ord-1',
          kot_number: 2,
          status: 'printed',
          printed_at: '2026-10-12T10:15:00Z',
          items: [
            {
              id: 'kitem-2',
              kot_id: 'kot-2',
              product_id: 'p-2',
              product_name: 'Farmhouse',
              quantity: 1,
            },
          ],
        },
      ],
      { lastUpdatedAt: '2026-10-12T10:15:00Z', lastId: 'kot-2' }
    );

    const kots = rawDb.prepare('SELECT id, kot_number FROM pos_kots WHERE order_id = ? ORDER BY kot_number ASC').all('ord-1') as {
      id: string;
      kot_number: number;
    }[];
    assert.equal(kots.length, 2);
    assert.equal(kots[0].id, 'kot-1');
    assert.equal(kots[1].id, 'kot-2');
    assert.equal(kots[1].kot_number, 2);

    const kitems = rawDb.prepare('SELECT id, kot_id, product_name FROM kot_items WHERE kot_id = ?').all('kot-2') as {
      id: string;
      kot_id: string;
      product_name: string;
    }[];
    assert.equal(kitems.length, 1);
    assert.equal(kitems[0].id, 'kitem-2');
    assert.equal(kitems[0].product_name, 'Farmhouse');
  });

  it('PENDING_ADDITIONAL_KOT_PULL_PRESERVED_PASS & PENDING_LOCAL_ADDITIONAL_KOT_PRESERVED_PASS: Pull protected when outbox operation pending', () => {
    const rawDb = dbManager.getRawDb();

    // Create local additional KOT #2 (creates outbox row for pos_kots with id = kot-local-2)
    appendOrderItemsAndKotTransaction(
      dbManager,
      {
        id: 'ord-1',
        channel: 'POS',
        order_type: 'DINE_IN',
        table_session_id: 'sess-1',
        status: 'kot_sent',
        version: 1,
        subtotal: 300,
        tax_total: 15,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 315,
        created_at: '2026-10-12T10:00:00Z',
        updated_at: '2026-10-12T10:15:00Z',
      },
      [
        {
          id: 'item-local-new',
          order_id: 'ord-1',
          product_id: 'p-2',
          product_name: 'Farmhouse',
          unit_price: 200,
          quantity: 1,
          tax_rate: 5,
          discount_amount: 0,
          line_total: 200,
          created_at: '2026-10-12T10:15:00Z',
        },
      ],
      {
        id: 'kot-local-2',
        order_id: 'ord-1',
        kot_number: 2,
        status: 'printed',
        printed_at: '2026-10-12T10:15:00Z',
      },
      [
        {
          id: 'kitem-local-2',
          kot_id: 'kot-local-2',
          product_id: 'p-2',
          product_name: 'Farmhouse',
          quantity: 1,
        },
      ]
    );

    // Verify outbox has pending entry
    const pending = getPendingOutboxEntries(rawDb);
    assert.ok(pending.some((p) => p.entity_id === 'kot-local-2'));

    // Pull attempts to apply orders update for ord-1
    const rowsApplied = applyPullBatchLocal(
      rawDb,
      'orders',
      [
        {
          id: 'ord-1',
          channel: 'POS',
          order_type: 'DINE_IN',
          table_session_id: 'sess-1',
          status: 'kot_sent',
          subtotal: 999,
          grand_total: 999,
          version: 1,
          created_at: '2026-10-12T10:00:00Z',
          updated_at: '2026-10-12T10:20:00Z',
          items: [],
        },
      ],
      { lastUpdatedAt: '2026-10-12T10:20:00Z', lastId: 'ord-1' }
    );

    // Pull hits pending protection!
    assert.equal(rowsApplied, 0);

    // Local state remains preserved
    const localOrder = rawDb.prepare('SELECT grand_total_paise FROM orders WHERE id = ?').get('ord-1') as { grand_total_paise: number };
    assert.equal(localOrder.grand_total_paise, 31500);

    const localItem = rawDb.prepare('SELECT id FROM order_items WHERE id = ?').get('item-local-new');
    assert.ok(localItem);
  });

  it('OFFLINE_ADDITIONAL_KOT_RECONNECT_PASS: Full append -> offline -> reconnect -> push -> pull sequence', async () => {
    const rawDb = dbManager.getRawDb();

    // 1. Initial order has KOT #1 (from beforeEach). Clear any lingering outbox rows.
    rawDb.prepare('DELETE FROM sync_outbox').run();

    // 2. Go offline & append new item + KOT #2
    const appendResult = appendOrderItemsAndKotTransaction(
      dbManager,
      {
        id: 'ord-1',
        channel: 'POS',
        order_type: 'DINE_IN',
        table_session_id: 'sess-1',
        status: 'kot_sent',
        version: 1,
        subtotal: 300,
        tax_total: 15,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 315,
        created_at: '2026-10-12T10:00:00Z',
        updated_at: '2026-10-12T10:20:00Z',
      },
      [
        {
          id: 'item-reconn-2',
          order_id: 'ord-1',
          product_id: 'p-2',
          product_name: 'Farmhouse',
          unit_price: 200,
          quantity: 1,
          tax_rate: 5,
          discount_amount: 0,
          line_total: 200,
          created_at: '2026-10-12T10:20:00Z',
        },
      ],
      {
        id: 'kot-reconn-2',
        order_id: 'ord-1',
        kot_number: 2,
        status: 'printed',
        printed_at: '2026-10-12T10:20:00Z',
      },
      [
        {
          id: 'kitem-reconn-2',
          kot_id: 'kot-reconn-2',
          product_id: 'p-2',
          product_name: 'Farmhouse',
          quantity: 1,
        },
      ]
    );

    assert.equal(appendResult.kot.kot_number, 2);
    assert.equal(appendResult.order.status, 'kot_sent');

    // 3. Outbox pending verification
    const pendingBeforePush = getPendingOutboxEntries(rawDb);
    assert.equal(pendingBeforePush.length, 1);
    assert.equal(pendingBeforePush[0].entity_type, 'pos_kots');
    assert.equal(pendingBeforePush[0].entity_id, 'kot-reconn-2');

    // 4. Reconnect: Push outbox via mock CloudRpcTransport
    let appendRpcCalled = false;
    let rpcOrderItemsCount = 0;
    let rpcKotNumber = 0;

    const mockTransport: CloudRpcTransport = {
      async syncOrder() {
        return true;
      },
      async replaceDraftOrder() {
        return true;
      },
      async syncKot() {
        return true;
      },
      async appendOrderItemsAndKot(order, orderItems, kot, kotItems) {
        appendRpcCalled = true;
        rpcOrderItemsCount = orderItems.length;
        rpcKotNumber = Number((kot as any).kot_number);
        return true;
      },
      async syncKotCorrection() {
        return true;
      },
      async syncBill() {
        return true;
      },
      async syncPayment() {
        return true;
      },
      async applyInventoryMovement() {
        return true;
      },
      async syncTableSession() {
        return true;
      },
    };

    const pushResult = await runPushCycle({
      dbManager,
      transport: mockTransport,
    });

    assert.equal(pushResult.status, 'COMPLETED');
    assert.equal(pushResult.processedCount, 1);
    assert.equal(appendRpcCalled, true);
    assert.equal(rpcOrderItemsCount, 1);
    assert.equal(rpcKotNumber, 2);

    // 5. Outbox acknowledged (empty)
    const pendingAfterPush = getPendingOutboxEntries(rawDb);
    assert.equal(pendingAfterPush.length, 0);

    // 6. Pull arrives for both orders and pos_kots
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
          subtotal: 300,
          tax_total: 15,
          discount_total: 0,
          delivery_charge: 0,
          grand_total: 315,
          version: 1,
          created_at: '2026-10-12T10:00:00Z',
          updated_at: '2026-10-12T10:20:00Z',
          items: [
            {
              id: 'item-1',
              order_id: 'ord-1',
              product_id: 'p-1',
              product_name: 'Margherita',
              unit_price: 100,
              quantity: 1,
              tax_rate: 5,
              discount_amount: 0,
              line_total: 100,
              created_at: '2026-10-12T10:00:00Z',
            },
            {
              id: 'item-reconn-2',
              order_id: 'ord-1',
              product_id: 'p-2',
              product_name: 'Farmhouse',
              unit_price: 200,
              quantity: 1,
              tax_rate: 5,
              discount_amount: 0,
              line_total: 200,
              created_at: '2026-10-12T10:20:00Z',
            },
          ],
        },
      ],
      { lastUpdatedAt: '2026-10-12T10:20:00Z', lastId: 'ord-1' }
    );

    applyPullBatchLocal(
      rawDb,
      'pos_kots',
      [
        {
          id: 'kot-reconn-2',
          order_id: 'ord-1',
          kot_number: 2,
          status: 'printed',
          printed_at: '2026-10-12T10:20:00Z',
          items: [
            {
              id: 'kitem-reconn-2',
              kot_id: 'kot-reconn-2',
              product_id: 'p-2',
              product_name: 'Farmhouse',
              quantity: 1,
            },
          ],
        },
      ],
      { lastUpdatedAt: '2026-10-12T10:20:00Z', lastId: 'kot-reconn-2' }
    );

    // 7. Verify post-pull invariants:
    // - No duplicate commercial items (exactly 2)
    const finalItems = rawDb.prepare('SELECT id FROM order_items WHERE order_id = ? ORDER BY id ASC').all('ord-1') as { id: string }[];
    assert.deepEqual(finalItems.map((i) => i.id), ['item-1', 'item-reconn-2']);

    // - No duplicate KOTs (exactly 2)
    const finalKots = rawDb.prepare('SELECT id, kot_number FROM pos_kots WHERE order_id = ? ORDER BY kot_number ASC').all('ord-1') as {
      id: string;
      kot_number: number;
    }[];
    assert.deepEqual(finalKots.map((k) => k.id), ['kot-1', 'kot-reconn-2']);
    assert.deepEqual(finalKots.map((k) => k.kot_number), [1, 2]);

    // - Order totals remain cumulative
    const finalOrder = rawDb.prepare('SELECT subtotal_paise, grand_total_paise, status, version FROM orders WHERE id = ?').get('ord-1') as {
      subtotal_paise: number;
      grand_total_paise: number;
      status: string;
      version: number;
    };
    assert.equal(finalOrder.subtotal_paise, 30000);
    assert.equal(finalOrder.grand_total_paise, 31500);
    assert.equal(finalOrder.status, 'kot_sent');
    assert.equal(finalOrder.version, 1);
  });
});
