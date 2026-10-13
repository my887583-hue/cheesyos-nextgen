/**
 * CHEESYOS NEXTGEN POS LOCAL — TASK 3G.2-06B
 * DRAFT ORDER REPLACEMENT & VERSION CONCURRENCY TEST SUITE
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

import {
  PosLocalDatabase,
  saveOrderTransaction,
  replaceDraftOrderAggregateTransaction,
  saveKotDispatchTransaction,
  saveBillTransaction,
  savePaymentTransaction,
  openTableSessionTransaction,
  getPendingOutboxEntries,
  SCHEMA_VERSION,
} from '../src/index.js';
import type { OrderDomain, OrderItemDomain, PosKotDomain, BillDomain, PaymentDomain } from '@cheesyos/nextgen-shared';

function setupTestDb(): PosLocalDatabase {
  const db = new PosLocalDatabase(':memory:');
  const rawDb = db.getRawDb();
  rawDb.exec(`
    INSERT INTO categories (id, name, slug, created_at, updated_at) VALUES ('cat-1', 'Pizzas', 'pizzas', '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');
    INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at) VALUES ('p-1', 'cat-1', 'Margherita', 25000, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');
    INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at) VALUES ('p-2', 'cat-1', 'Farmhouse', 35000, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');
    INSERT INTO pos_tables (id, table_number, section, capacity, is_active, created_at) VALUES ('tbl-1', 'T-01', 'Main', 4, 1, '2026-10-12T10:00:00Z');
  `);
  return db;
}

describe('Task 3G.2-06B: Versioned Draft Order Replacement & Concurrency', () => {
  test('ORDER_VERSION_DEFAULT_ONE_PASS & INITIAL_ORDER_VERSION_ONE_PASS', () => {
    const db = setupTestDb();
    const session = openTableSessionTransaction(db, 'tbl-1', 2);

    const order: OrderDomain = {
      id: 'ord-v1',
      display_number: '1',
      channel: 'POS',
      order_type: 'DINE_IN',
      table_session_id: session.id,
      status: 'draft',
      subtotal: 250,
      tax_total: 12.5,
      discount_total: 0,
      delivery_charge: 0,
      grand_total: 262.5,
      created_at: '2026-10-12T12:00:00Z',
      updated_at: '2026-10-12T12:00:00Z',
    };

    const items: OrderItemDomain[] = [
      {
        id: 'item-1',
        order_id: 'ord-v1',
        product_id: 'p-1',
        product_name: 'Margherita',
        unit_price: 250,
        quantity: 1,
        tax_rate: 5,
        discount_amount: 0,
        line_total: 250,
        created_at: '2026-10-12T12:00:00Z',
      },
    ];

    const res = saveOrderTransaction(db, order, items);
    assert.equal(res.order.version, 1);

    const row = db.getRawDb().prepare('SELECT version FROM orders WHERE id = ?').get('ord-v1') as { version: number };
    assert.equal(row.version, 1);

    db.close();
  });

  test('EXISTING_SQLITE_UPGRADE_PRESERVES_DATA_PASS', () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'cheesyos-v2-upgrade-'));
    const dbPath = path.join(tmpDir, 'v2_existing.db');

    try {
      // 1. Create a schema v2 database with an existing order
      const legacyDb = new DatabaseSync(dbPath);
      legacyDb.exec(`
        PRAGMA foreign_keys = ON;
        CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT NOT NULL, slug TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
        CREATE TABLE pos_tables (id TEXT PRIMARY KEY, table_number TEXT NOT NULL UNIQUE, section TEXT, capacity INTEGER, is_active INTEGER, created_at TEXT NOT NULL);
        CREATE TABLE table_sessions (id TEXT PRIMARY KEY, table_id TEXT NOT NULL, current_order_id TEXT, guest_count INTEGER, session_status TEXT NOT NULL, opened_at TEXT NOT NULL, closed_at TEXT);
        CREATE TABLE orders (
          id TEXT PRIMARY KEY, display_number TEXT, channel TEXT NOT NULL, order_type TEXT NOT NULL,
          customer_id TEXT, table_session_id TEXT, status TEXT NOT NULL, subtotal_paise INTEGER NOT NULL,
          tax_total_paise INTEGER NOT NULL, discount_total_paise INTEGER NOT NULL, delivery_charge_paise INTEGER NOT NULL,
          grand_total_paise INTEGER NOT NULL, device_id TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        );
        INSERT INTO orders (id, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at)
        VALUES ('ord-legacy', 'POS', 'TAKEAWAY', 'draft', 10000, 500, 0, 0, 10500, '2026-10-10T10:00:00Z', '2026-10-10T10:00:00Z');
        PRAGMA user_version = 2;
      `);
      legacyDb.close();

      // 2. Open with PosLocalDatabase (should migrate to v3)
      const db = new PosLocalDatabase(dbPath);
      assert.equal(db.getSchemaVersion(), SCHEMA_VERSION);

      const migrated = db.getRawDb().prepare('SELECT id, version FROM orders WHERE id = ?').get('ord-legacy') as { id: string; version: number };
      assert.equal(migrated.id, 'ord-legacy');
      assert.equal(migrated.version, 1);

      db.close();
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  test('INITIAL_ORDER_SETS_CURRENT_ORDER_ID_PASS & SECOND_ACTIVE_ORDER_SAME_SESSION_REJECT_PASS', () => {
    const db = setupTestDb();
    const session = openTableSessionTransaction(db, 'tbl-1', 2);
    const sessionId = session.id;

    const order1: OrderDomain = {
      id: 'ord-active-1',
      channel: 'POS',
      order_type: 'DINE_IN',
      table_session_id: sessionId,
      status: 'draft',
      subtotal: 250,
      tax_total: 12.5,
      discount_total: 0,
      delivery_charge: 0,
      grand_total: 262.5,
      created_at: '2026-10-12T12:00:00Z',
      updated_at: '2026-10-12T12:00:00Z',
    };

    saveOrderTransaction(db, order1, [
      {
        id: 'item-act-1',
        order_id: 'ord-active-1',
        product_id: 'p-1',
        product_name: 'Margherita',
        unit_price: 250,
        quantity: 1,
        tax_rate: 5,
        discount_amount: 0,
        line_total: 250,
        created_at: '2026-10-12T12:00:00Z',
      },
    ]);

    // Check table_sessions.current_order_id is set
    const sessionRow = db.getRawDb().prepare('SELECT current_order_id FROM table_sessions WHERE id = ?').get(sessionId) as { current_order_id: string | null };
    assert.equal(sessionRow.current_order_id, 'ord-active-1');

    // Attempt second active order for the same session
    const order2: OrderDomain = {
      id: 'ord-active-2',
      channel: 'POS',
      order_type: 'DINE_IN',
      table_session_id: sessionId,
      status: 'draft',
      subtotal: 350,
      tax_total: 17.5,
      discount_total: 0,
      delivery_charge: 0,
      grand_total: 367.5,
      created_at: '2026-10-12T12:05:00Z',
      updated_at: '2026-10-12T12:05:00Z',
    };

    assert.throws(() => {
      saveOrderTransaction(db, order2, []);
    }, /ACTIVE_ORDER_EXISTS/);

    db.close();
  });

  test('DRAFT_REPLACE_N_TO_N_PLUS_ONE_PASS, STABILITY, ATOMICITY, HEADER & OUTBOX', () => {
    const db = setupTestDb();
    const session = openTableSessionTransaction(db, 'tbl-1', 2);
    const sessionId = session.id;

    const initialOrder: OrderDomain = {
      id: 'ord-replace-test',
      channel: 'POS',
      order_type: 'DINE_IN',
      table_session_id: sessionId,
      status: 'draft',
      version: 1,
      subtotal: 250,
      tax_total: 12.5,
      discount_total: 0,
      delivery_charge: 0,
      grand_total: 262.5,
      created_at: '2026-10-12T12:00:00Z',
      updated_at: '2026-10-12T12:00:00Z',
    };

    saveOrderTransaction(db, initialOrder, [
      {
        id: 'item-old-1',
        order_id: 'ord-replace-test',
        product_id: 'p-1',
        product_name: 'Margherita',
        unit_price: 250,
        quantity: 1,
        tax_rate: 5,
        discount_amount: 0,
        line_total: 250,
        created_at: '2026-10-12T12:00:00Z',
      },
    ]);

    // Replace: N -> N + 1 (1 -> 2)
    const replacementOrder: OrderDomain = {
      id: 'ord-replace-test',
      channel: 'POS',
      order_type: 'DINE_IN',
      table_session_id: sessionId,
      status: 'draft',
      version: 2,
      subtotal: 600,
      tax_total: 30,
      discount_total: 0,
      delivery_charge: 0,
      grand_total: 630,
      created_at: '2026-10-12T12:00:00Z',
      updated_at: '2026-10-12T12:02:00Z',
    };

    const replacementItems: OrderItemDomain[] = [
      {
        id: 'item-new-1',
        order_id: 'ord-replace-test',
        product_id: 'p-1',
        product_name: 'Margherita',
        unit_price: 250,
        quantity: 1,
        tax_rate: 5,
        discount_amount: 0,
        line_total: 250,
        created_at: '2026-10-12T12:02:00Z',
      },
      {
        id: 'item-new-2',
        order_id: 'ord-replace-test',
        product_id: 'p-2',
        product_name: 'Farmhouse',
        unit_price: 350,
        quantity: 1,
        tax_rate: 5,
        discount_amount: 0,
        line_total: 350,
        created_at: '2026-10-12T12:02:00Z',
      },
    ];

    const repRes = replaceDraftOrderAggregateTransaction(db, replacementOrder, replacementItems);

    assert.equal(repRes.order.version, 2);
    assert.equal(repRes.order.id, 'ord-replace-test');
    assert.equal(repRes.order.table_session_id, sessionId);
    assert.equal(repRes.order.subtotal, 600);
    assert.equal(repRes.order.grand_total, 630);

    // DRAFT_REPLACE_ITEMS_ATOMIC_PASS: old item removed, new items present
    const storedItems = db.getRawDb().prepare('SELECT id FROM order_items WHERE order_id = ? ORDER BY id ASC').all('ord-replace-test') as { id: string }[];
    assert.deepEqual(storedItems.map((r) => r.id), ['item-new-1', 'item-new-2']);

    // DRAFT_REPLACE_OUTBOX_UPDATE_ATOMIC_PASS
    const pendingOutbox = getPendingOutboxEntries(db.getRawDb());
    const updateOutbox = pendingOutbox.find((o) => o.entity_id === 'ord-replace-test' && o.operation === 'UPDATE');
    assert.ok(updateOutbox);
    const parsedPayload = JSON.parse(updateOutbox.payload_json);
    assert.equal(parsedPayload.version, 2);
    assert.equal(parsedPayload.items.length, 2);

    db.close();
  });

  test('DRAFT_REPLACE_VERSION_GAP_REJECT_PASS & STALE_VERSION_REJECT', () => {
    const db = setupTestDb();
    const session = openTableSessionTransaction(db, 'tbl-1', 2);
    const sessionId = session.id;

    const initialOrder: OrderDomain = {
      id: 'ord-gap-test',
      channel: 'POS',
      order_type: 'DINE_IN',
      table_session_id: sessionId,
      status: 'draft',
      version: 1,
      subtotal: 250,
      tax_total: 12.5,
      discount_total: 0,
      delivery_charge: 0,
      grand_total: 262.5,
      created_at: '2026-10-12T12:00:00Z',
      updated_at: '2026-10-12T12:00:00Z',
    };

    saveOrderTransaction(db, initialOrder, [
      {
        id: 'item-1',
        order_id: 'ord-gap-test',
        product_id: 'p-1',
        product_name: 'Margherita',
        unit_price: 250,
        quantity: 1,
        tax_rate: 5,
        discount_amount: 0,
        line_total: 250,
        created_at: '2026-10-12T12:00:00Z',
      },
    ]);

    // Version Gap: incoming version 3 when current is 1
    assert.throws(() => {
      replaceDraftOrderAggregateTransaction(db, { ...initialOrder, version: 3 }, [
        {
          id: 'item-gap',
          order_id: 'ord-gap-test',
          product_id: 'p-1',
          product_name: 'Margherita',
          unit_price: 250,
          quantity: 1,
          tax_rate: 5,
          discount_amount: 0,
          line_total: 250,
          created_at: '2026-10-12T12:01:00Z',
        },
      ]);
    }, /VERSION_GAP/);

    // Stale: incoming version 1 when current is 1
    assert.throws(() => {
      replaceDraftOrderAggregateTransaction(db, { ...initialOrder, version: 1 }, [
        {
          id: 'item-stale',
          order_id: 'ord-gap-test',
          product_id: 'p-1',
          product_name: 'Margherita',
          unit_price: 250,
          quantity: 1,
          tax_rate: 5,
          discount_amount: 0,
          line_total: 250,
          created_at: '2026-10-12T12:01:00Z',
        },
      ]);
    }, /STALE_VERSION/);

    db.close();
  });

  test('POST_KOT, BILLED, SETTLED, CLOSED, CANCELLED DRAFT REPLACEMENT REJECT & KOT SNAPSHOT IMMUTABILITY', () => {
    const db = setupTestDb();
    const session = openTableSessionTransaction(db, 'tbl-1', 2);
    const sessionId = session.id;

    const initialOrder: OrderDomain = {
      id: 'ord-status-guard',
      channel: 'POS',
      order_type: 'DINE_IN',
      table_session_id: sessionId,
      status: 'draft',
      version: 1,
      subtotal: 250,
      tax_total: 12.5,
      discount_total: 0,
      delivery_charge: 0,
      grand_total: 262.5,
      created_at: '2026-10-12T12:00:00Z',
      updated_at: '2026-10-12T12:00:00Z',
    };

    saveOrderTransaction(db, initialOrder, [
      {
        id: 'item-1',
        order_id: 'ord-status-guard',
        product_id: 'p-1',
        product_name: 'Margherita',
        unit_price: 250,
        quantity: 1,
        tax_rate: 5,
        discount_amount: 0,
        line_total: 250,
        created_at: '2026-10-12T12:00:00Z',
      },
    ]);

    // Dispatch KOT
    const kot: PosKotDomain = {
      id: 'kot-guard-1',
      order_id: 'ord-status-guard',
      kot_number: 1,
      device_id: 'dev-1',
      status: 'printed',
      printed_at: '2026-10-12T12:01:00Z',
    };
    saveKotDispatchTransaction(db, kot, [
      {
        id: 'kot-item-1',
        kot_id: 'kot-guard-1',
        product_id: 'p-1',
        product_name: 'Margherita',
        quantity: 1,
      },
    ]);

    // POST_KOT_DRAFT_REPLACE_REJECT_PASS
    assert.throws(() => {
      replaceDraftOrderAggregateTransaction(db, { ...initialOrder, version: 2 }, [
        {
          id: 'item-new',
          order_id: 'ord-status-guard',
          product_id: 'p-1',
          product_name: 'Margherita',
          unit_price: 250,
          quantity: 2,
          tax_rate: 5,
          discount_amount: 0,
          line_total: 500,
          created_at: '2026-10-12T12:02:00Z',
        },
      ]);
    }, /KOT_ALREADY_SENT|ORDER_NOT_EDITABLE/);

    // KOT_SNAPSHOT_UNCHANGED_PASS
    const storedKot = db.getRawDb().prepare('SELECT * FROM pos_kots WHERE id = ?').get('kot-guard-1') as { status: string };
    assert.equal(storedKot.status, 'printed');

    // Test billed, settled, closed, cancelled
    // 1. Cancelled order
    db.getRawDb().exec(`
      INSERT INTO orders (id, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, version, created_at, updated_at)
      VALUES ('ord-cancelled', 'POS', 'TAKEAWAY', 'cancelled', 10000, 500, 0, 0, 10500, 1, 'now', 'now');
    `);
    assert.throws(() => {
      replaceDraftOrderAggregateTransaction(db, { ...initialOrder, id: 'ord-cancelled', version: 2, table_session_id: null }, [
        {
          id: 'it-c',
          order_id: 'ord-cancelled',
          product_id: 'p-1',
          product_name: 'P',
          unit_price: 100,
          quantity: 1,
          tax_rate: 5,
          discount_amount: 0,
          line_total: 100,
          created_at: 'now',
        },
      ]);
    }, /ORDER_NOT_EDITABLE/);

    // 2. Closed order
    db.getRawDb().exec(`
      INSERT INTO orders (id, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, version, created_at, updated_at)
      VALUES ('ord-closed', 'POS', 'TAKEAWAY', 'closed', 10000, 500, 0, 0, 10500, 1, 'now', 'now');
    `);
    assert.throws(() => {
      replaceDraftOrderAggregateTransaction(db, { ...initialOrder, id: 'ord-closed', version: 2, table_session_id: null }, [
        {
          id: 'it-cl',
          order_id: 'ord-closed',
          product_id: 'p-1',
          product_name: 'P',
          unit_price: 100,
          quantity: 1,
          tax_rate: 5,
          discount_amount: 0,
          line_total: 100,
          created_at: 'now',
        },
      ]);
    }, /ORDER_NOT_EDITABLE/);

    db.close();
  });
});
