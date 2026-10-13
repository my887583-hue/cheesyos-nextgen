/**
 * CHEESYOS NEXTGEN POS SYNC — TASK 3G.2-06B
 * DRAFT ORDER REPLACEMENT & SAFE PULL RECONCILIATION TEST SUITE
 */

import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  PosLocalDatabase,
  saveOrderTransaction,
  replaceDraftOrderAggregateTransaction,
  saveKotDispatchTransaction,
  applyPullBatchLocal,
  getPendingOutboxEntries,
} from '@cheesyos/pos-local';
import { runPushCycle, CloudRpcTransport } from '../src/index.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const TEST_DB_PATH = path.join(__dirname, 'temp_draft_pull_test.db');

describe('Task 3G.2-06B: Draft Order Sync & Pull Reconciliation', () => {
  let dbManager: PosLocalDatabase;

  beforeEach(() => {
    if (fs.existsSync(TEST_DB_PATH)) fs.unlinkSync(TEST_DB_PATH);
    dbManager = new PosLocalDatabase(TEST_DB_PATH);
    const rawDb = dbManager.getRawDb();
    rawDb.exec(`
      INSERT INTO categories (id, name, slug, created_at, updated_at) VALUES ('cat-1', 'Pizzas', 'pizzas', '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');
      INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at) VALUES ('p-1', 'cat-1', 'Margherita', 25000, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');
      INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at) VALUES ('p-2', 'cat-1', 'Farmhouse', 35000, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');
      INSERT INTO pos_tables (id, table_number, section, capacity, is_active, created_at) VALUES ('tbl-1', 'T-01', 'Main', 4, 1, '2026-10-12T10:00:00Z');
      INSERT INTO table_sessions (id, table_id, guest_count, session_status, opened_at) VALUES ('sess-1', 'tbl-1', 2, 'open', '2026-10-12T10:00:00Z');
    `);
  });

  afterEach(() => {
    dbManager.close();
    if (fs.existsSync(TEST_DB_PATH)) fs.unlinkSync(TEST_DB_PATH);
  });

  it('PULL_NEWER_DRAFT_REPLACES_AGGREGATE_PASS & PULL_REMOVES_STALE_DRAFT_ITEM_PASS', () => {
    const rawDb = dbManager.getRawDb();
    // 1. Local order with V1 and items: item-1 and item-2
    rawDb.exec(`
      INSERT INTO orders (id, channel, order_type, table_session_id, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, version, created_at, updated_at)
      VALUES ('ord-pull-1', 'POS', 'DINE_IN', 'sess-1', 'draft', 50000, 2500, 0, 0, 52500, 1, '2026-10-12T12:00:00Z', '2026-10-12T12:00:00Z');
      INSERT INTO order_items (id, order_id, product_id, product_name, unit_price_paise, quantity, tax_rate, discount_amount_paise, line_total_paise, created_at)
      VALUES ('item-1', 'ord-pull-1', 'p-1', 'Margherita', 25000, 1, 5.0, 0, 25000, '2026-10-12T12:00:00Z');
      INSERT INTO order_items (id, order_id, product_id, product_name, unit_price_paise, quantity, tax_rate, discount_amount_paise, line_total_paise, created_at)
      VALUES ('item-2', 'ord-pull-1', 'p-1', 'Margherita', 25000, 1, 5.0, 0, 25000, '2026-10-12T12:00:00Z');
    `);

    // 2. Pull brings newer draft version 2 where item-1 was removed, and item-3 was added
    applyPullBatchLocal(
      dbManager.getRawDb(),
      'orders',
      [
        {
          id: 'ord-pull-1',
          display_number: '1',
          channel: 'POS',
          order_type: 'DINE_IN',
          table_session_id: 'sess-1',
          status: 'draft',
          subtotal: 600,
          tax_total: 30,
          discount_total: 0,
          delivery_charge: 0,
          grand_total: 630,
          version: 2,
          created_at: '2026-10-12T12:00:00Z',
          updated_at: '2026-10-12T12:05:00Z',
          items: [
            {
              id: 'item-2',
              order_id: 'ord-pull-1',
              product_id: 'p-1',
              product_name: 'Margherita',
              unit_price: 250,
              quantity: 1,
              tax_rate: 5,
              discount_amount: 0,
              line_total: 250,
              created_at: '2026-10-12T12:00:00Z',
            },
            {
              id: 'item-3',
              order_id: 'ord-pull-1',
              product_id: 'p-2',
              product_name: 'Farmhouse',
              unit_price: 350,
              quantity: 1,
              tax_rate: 5,
              discount_amount: 0,
              line_total: 350,
              created_at: '2026-10-12T12:05:00Z',
            },
          ],
        },
      ],
      { lastUpdatedAt: '2026-10-12T12:05:00Z', lastId: 'ord-pull-1' }
    );

    // Verify order version is 2
    const orderRow = rawDb.prepare('SELECT version, grand_total_paise FROM orders WHERE id = ?').get('ord-pull-1') as { version: number; grand_total_paise: number };
    assert.equal(orderRow.version, 2);
    assert.equal(orderRow.grand_total_paise, 63000);

    // Stale item-1 was removed, item-2 and item-3 exist
    const items = rawDb.prepare('SELECT id FROM order_items WHERE order_id = ? ORDER BY id ASC').all('ord-pull-1') as { id: string }[];
    assert.deepEqual(items.map((it) => it.id), ['item-2', 'item-3']);
  });

  it('PULL_EMPTY_DRAFT_ITEMS_SAFE_PASS: Safe when incoming draft has 0 items', () => {
    const rawDb = dbManager.getRawDb();
    rawDb.exec(`
      INSERT INTO orders (id, channel, order_type, table_session_id, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, version, created_at, updated_at)
      VALUES ('ord-pull-empty', 'POS', 'DINE_IN', 'sess-1', 'draft', 25000, 1250, 0, 0, 26250, 1, '2026-10-12T12:00:00Z', '2026-10-12T12:00:00Z');
      INSERT INTO order_items (id, order_id, product_id, product_name, unit_price_paise, quantity, tax_rate, discount_amount_paise, line_total_paise, created_at)
      VALUES ('item-empty-1', 'ord-pull-empty', 'p-1', 'Margherita', 25000, 1, 5.0, 0, 25000, '2026-10-12T12:00:00Z');
    `);

    // Pull brings version 2 with 0 items
    applyPullBatchLocal(
      dbManager.getRawDb(),
      'orders',
      [
        {
          id: 'ord-pull-empty',
          channel: 'POS',
          order_type: 'DINE_IN',
          table_session_id: 'sess-1',
          status: 'draft',
          subtotal: 0,
          tax_total: 0,
          discount_total: 0,
          delivery_charge: 0,
          grand_total: 0,
          version: 2,
          created_at: '2026-10-12T12:00:00Z',
          updated_at: '2026-10-12T12:05:00Z',
          items: [],
        },
      ],
      { lastUpdatedAt: '2026-10-12T12:05:00Z', lastId: 'ord-pull-empty' }
    );

    const items = rawDb.prepare('SELECT id FROM order_items WHERE order_id = ?').all('ord-pull-empty');
    assert.equal(items.length, 0);
  });

  it('PULL_OLDER_VERSION_SKIPPED_PASS & PULL_EQUAL_VERSION_NON_DESTRUCTIVE_PASS', () => {
    const rawDb = dbManager.getRawDb();
    rawDb.exec(`
      INSERT INTO orders (id, channel, order_type, table_session_id, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, version, created_at, updated_at)
      VALUES ('ord-v2-local', 'POS', 'DINE_IN', 'sess-1', 'draft', 35000, 1750, 0, 0, 36750, 2, '2026-10-12T12:00:00Z', '2026-10-12T12:05:00Z');
      INSERT INTO order_items (id, order_id, product_id, product_name, unit_price_paise, quantity, tax_rate, discount_amount_paise, line_total_paise, created_at)
      VALUES ('item-v2-local', 'ord-v2-local', 'p-2', 'Farmhouse', 35000, 1, 5.0, 0, 35000, '2026-10-12T12:05:00Z');
    `);

    // 1. Pull with older version (version 1) is skipped
    applyPullBatchLocal(
      dbManager.getRawDb(),
      'orders',
      [
        {
          id: 'ord-v2-local',
          channel: 'POS',
          order_type: 'DINE_IN',
          table_session_id: 'sess-1',
          status: 'draft',
          subtotal: 100,
          grand_total: 105,
          version: 1,
          created_at: '2026-10-12T12:00:00Z',
          updated_at: '2026-10-12T12:01:00Z',
          items: [],
        },
      ],
      { lastUpdatedAt: '2026-10-12T12:01:00Z', lastId: 'ord-v2-local' }
    );

    const orderAfterOlder = rawDb.prepare('SELECT version, grand_total_paise FROM orders WHERE id = ?').get('ord-v2-local') as { version: number; grand_total_paise: number };
    assert.equal(orderAfterOlder.version, 2);
    assert.equal(orderAfterOlder.grand_total_paise, 36750);

    // 2. Pull with equal version (version 2) is non-destructive
    applyPullBatchLocal(
      dbManager.getRawDb(),
      'orders',
      [
        {
          id: 'ord-v2-local',
          channel: 'POS',
          order_type: 'DINE_IN',
          table_session_id: 'sess-1',
          status: 'draft',
          subtotal: 350,
          grand_total: 367.5,
          version: 2,
          created_at: '2026-10-12T12:00:00Z',
          updated_at: '2026-10-12T12:05:00Z',
          items: [
            {
              id: 'item-v2-local',
              order_id: 'ord-v2-local',
              product_id: 'p-2',
              product_name: 'Farmhouse',
              unit_price: 350,
              quantity: 1,
              line_total: 350,
              created_at: '2026-10-12T12:05:00Z',
            },
          ],
        },
      ],
      { lastUpdatedAt: '2026-10-12T12:05:00Z', lastId: 'ord-v2-local' }
    );

    const itemsAfterEqual = rawDb.prepare('SELECT id FROM order_items WHERE order_id = ?').all('ord-v2-local') as { id: string }[];
    assert.equal(itemsAfterEqual.length, 1);
    assert.equal(itemsAfterEqual[0].id, 'item-v2-local');
  });

  it('PULL_PENDING_LOCAL_UPDATE_PRESERVED_PASS & PULL_PENDING_LOCAL_ITEMS_NOT_DELETED_PASS', () => {
    const rawDb = dbManager.getRawDb();
    // Local order at V1
    saveOrderTransaction(
      dbManager,
      {
        id: 'ord-pending-prot',
        channel: 'POS',
        order_type: 'DINE_IN',
        table_session_id: 'sess-1',
        status: 'draft',
        version: 1,
        subtotal: 250,
        tax_total: 12.5,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 262.5,
        created_at: '2026-10-12T12:00:00Z',
        updated_at: '2026-10-12T12:00:00Z',
      },
      [
        {
          id: 'item-p-1',
          order_id: 'ord-pending-prot',
          product_id: 'p-1',
          product_name: 'Margherita',
          unit_price: 250,
          quantity: 1,
          tax_rate: 5,
          discount_amount: 0,
          line_total: 250,
          created_at: '2026-10-12T12:00:00Z',
        },
      ]
    );

    // Local edit: V1 -> V2 with item-p-2
    replaceDraftOrderAggregateTransaction(
      dbManager,
      {
        id: 'ord-pending-prot',
        channel: 'POS',
        order_type: 'DINE_IN',
        table_session_id: 'sess-1',
        status: 'draft',
        version: 2,
        subtotal: 350,
        tax_total: 17.5,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 367.5,
        created_at: '2026-10-12T12:00:00Z',
        updated_at: '2026-10-12T12:02:00Z',
      },
      [
        {
          id: 'item-p-2',
          order_id: 'ord-pending-prot',
          product_id: 'p-2',
          product_name: 'Farmhouse',
          unit_price: 350,
          quantity: 1,
          tax_rate: 5,
          discount_amount: 0,
          line_total: 350,
          created_at: '2026-10-12T12:02:00Z',
        },
      ]
    );

    // There is a pending outbox entry for ord-pending-prot
    const pending = getPendingOutboxEntries(rawDb);
    assert.ok(pending.some((p) => p.entity_id === 'ord-pending-prot'));

    // Pull attempts to apply cloud V3 with different items
    const rowsApplied = applyPullBatchLocal(
      dbManager.getRawDb(),
      'orders',
      [
        {
          id: 'ord-pending-prot',
          channel: 'POS',
          order_type: 'DINE_IN',
          table_session_id: 'sess-1',
          status: 'draft',
          subtotal: 999,
          grand_total: 999,
          version: 3,
          created_at: '2026-10-12T12:00:00Z',
          updated_at: '2026-10-12T12:10:00Z',
          items: [],
        },
      ],
      { lastUpdatedAt: '2026-10-12T12:10:00Z', lastId: 'ord-pending-prot' }
    );

    // Pull hits pending protection!
    assert.equal(rowsApplied, 0);

    // Local state remains version 2 and local items preserved
    const localOrder = rawDb.prepare('SELECT version, grand_total_paise FROM orders WHERE id = ?').get('ord-pending-prot') as { version: number; grand_total_paise: number };
    assert.equal(localOrder.version, 2);
    assert.equal(localOrder.grand_total_paise, 36750);

    const localItems = rawDb.prepare('SELECT id FROM order_items WHERE order_id = ?').all('ord-pending-prot') as { id: string }[];
    assert.equal(localItems.length, 1);
    assert.equal(localItems[0].id, 'item-p-2');
  });

  it('PULL_KOT_ITEMS_UNCHANGED_PASS: Pull reconciliation never alters KOT snapshots', () => {
    const rawDb = dbManager.getRawDb();
    rawDb.exec(`
      INSERT INTO orders (id, channel, order_type, table_session_id, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, version, created_at, updated_at)
      VALUES ('ord-kot-protect', 'POS', 'DINE_IN', 'sess-1', 'draft', 25000, 1250, 0, 0, 26250, 1, '2026-10-12T12:00:00Z', '2026-10-12T12:00:00Z');
      INSERT INTO pos_kots (id, order_id, kot_number, status, printed_at)
      VALUES ('kot-fixed-1', 'ord-kot-protect', 1, 'printed', '2026-10-12T12:01:00Z');
      INSERT INTO kot_items (id, kot_id, product_id, product_name, quantity)
      VALUES ('kot-item-fixed', 'kot-fixed-1', 'p-1', 'Margherita', 1);
    `);

    // Pull brings orders
    applyPullBatchLocal(
      dbManager.getRawDb(),
      'orders',
      [
        {
          id: 'ord-kot-protect',
          channel: 'POS',
          order_type: 'DINE_IN',
          table_session_id: 'sess-1',
          status: 'draft',
          subtotal: 500,
          grand_total: 525,
          version: 2,
          created_at: '2026-10-12T12:00:00Z',
          updated_at: '2026-10-12T12:05:00Z',
          items: [],
        },
      ],
      { lastUpdatedAt: '2026-10-12T12:05:00Z', lastId: 'ord-kot-protect' }
    );

    const kotRow = rawDb.prepare('SELECT id, status FROM pos_kots WHERE id = ?').get('kot-fixed-1') as { id: string; status: string };
    assert.equal(kotRow.status, 'printed');

    const kotItemRow = rawDb.prepare('SELECT id, product_name FROM kot_items WHERE id = ?').get('kot-item-fixed') as { id: string; product_name: string };
    assert.equal(kotItemRow.product_name, 'Margherita');
  });

  it('OFFLINE_DRAFT_UPDATE_RECONNECT_PASS: Full reconnect sequence', async () => {
    const rawDb = dbManager.getRawDb();

    // Step 1: Initial local draft V1
    saveOrderTransaction(
      dbManager,
      {
        id: 'ord-reconn-1',
        channel: 'POS',
        order_type: 'DINE_IN',
        table_session_id: 'sess-1',
        status: 'draft',
        version: 1,
        subtotal: 250,
        tax_total: 12.5,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 262.5,
        created_at: '2026-10-12T12:00:00Z',
        updated_at: '2026-10-12T12:00:00Z',
      },
      [
        {
          id: 'item-rc-1',
          order_id: 'ord-reconn-1',
          product_id: 'p-1',
          product_name: 'Margherita',
          unit_price: 250,
          quantity: 1,
          tax_rate: 5,
          discount_amount: 0,
          line_total: 250,
          created_at: '2026-10-12T12:00:00Z',
        },
      ]
    );

    // Initial outbox acknowledged (simulating already pushed V1)
    const initialOutbox = getPendingOutboxEntries(rawDb);
    for (const ob of initialOutbox) {
      rawDb.prepare('DELETE FROM sync_outbox WHERE id = ?').run(ob.id);
    }

    // Step 2: Offline edit -> local V2 + UPDATE outbox
    replaceDraftOrderAggregateTransaction(
      dbManager,
      {
        id: 'ord-reconn-1',
        channel: 'POS',
        order_type: 'DINE_IN',
        table_session_id: 'sess-1',
        status: 'draft',
        version: 2,
        subtotal: 600,
        tax_total: 30,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 630,
        created_at: '2026-10-12T12:00:00Z',
        updated_at: '2026-10-12T12:05:00Z',
      },
      [
        {
          id: 'item-rc-2',
          order_id: 'ord-reconn-1',
          product_id: 'p-2',
          product_name: 'Farmhouse',
          unit_price: 350,
          quantity: 1,
          tax_rate: 5,
          discount_amount: 0,
          line_total: 350,
          created_at: '2026-10-12T12:05:00Z',
        },
        {
          id: 'item-rc-1',
          order_id: 'ord-reconn-1',
          product_id: 'p-1',
          product_name: 'Margherita',
          unit_price: 250,
          quantity: 1,
          tax_rate: 5,
          discount_amount: 0,
          line_total: 250,
          created_at: '2026-10-12T12:00:00Z',
        },
      ]
    );

    const pendingAfterEdit = getPendingOutboxEntries(rawDb);
    assert.equal(pendingAfterEdit.length, 1);
    assert.equal(pendingAfterEdit[0].operation, 'UPDATE');

    // Step 3: Reconnect — push cycle runs
    let replacedInCloud = false;
    let cloudOrderReceived: any = null;
    let cloudItemsReceived: any[] = [];

    const mockTransport: CloudRpcTransport = {
      async syncOrder() {
        return true;
      },
      async replaceDraftOrder(order, items) {
        replacedInCloud = true;
        cloudOrderReceived = order;
        cloudItemsReceived = items;
        return true;
      },
      async syncKot() {
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
    assert.equal(pushResult.successCount, 1);
    assert.ok(replacedInCloud);
    assert.equal(cloudOrderReceived.version, 2);
    assert.equal(cloudItemsReceived.length, 2);

    // Outbox is empty now
    const pendingAfterPush = getPendingOutboxEntries(rawDb);
    assert.equal(pendingAfterPush.length, 0);

    // Step 4: Subsequent pull brings cloud V2
    applyPullBatchLocal(
      dbManager.getRawDb(),
      'orders',
      [
        {
          ...cloudOrderReceived,
          items: cloudItemsReceived,
        },
      ],
      { lastUpdatedAt: '2026-10-12T12:05:00Z', lastId: 'ord-reconn-1' }
    );

    // Step 5: Assert final state: V2, no phantom items, no lost items
    const finalOrder = rawDb.prepare('SELECT version, grand_total_paise FROM orders WHERE id = ?').get('ord-reconn-1') as { version: number; grand_total_paise: number };
    assert.equal(finalOrder.version, 2);
    assert.equal(finalOrder.grand_total_paise, 63000);

    const finalItems = rawDb.prepare('SELECT id FROM order_items WHERE order_id = ? ORDER BY id ASC').all('ord-reconn-1') as { id: string }[];
    assert.deepEqual(finalItems.map((it) => it.id), ['item-rc-1', 'item-rc-2']);
  });
});
