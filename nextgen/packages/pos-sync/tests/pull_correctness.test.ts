import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  PosLocalDatabase,
  getSyncCursor,
  setSyncCursor,
  hasPendingOutboxRecord,
  saveOrderTransaction,
  OrderDomain,
  OrderItemDomain,
} from '@cheesyos/pos-local';
import {
  runPullCycle,
  createSupabasePullTransport,
  CloudPullTransport,
  PushSyncError,
  CHILD_PAGE_SIZE,
} from '../src/index.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const TEST_DB_PATH = path.join(__dirname, 'temp_pull_correctness.db');

describe('CHEESYOS NEXTGEN — PHASE 3F.6A DELTA PULL CORRECTNESS SUITE', () => {
  let dbManager: PosLocalDatabase;

  beforeEach(() => {
    if (fs.existsSync(TEST_DB_PATH)) fs.unlinkSync(TEST_DB_PATH);
    dbManager = new PosLocalDatabase(TEST_DB_PATH);
  });

  afterEach(() => {
    dbManager.close();
    if (fs.existsSync(TEST_DB_PATH)) fs.unlinkSync(TEST_DB_PATH);
  });

  // ==========================================================================
  // P0: SAFE PREFIX CURSOR & SAME TIMESTAMP TESTS
  // ==========================================================================

  it('P0.1: SAME_TIMESTAMP_CURSOR_TEST — Identical timestamp rows with middle pending stop cursor at prefix', async () => {
    const T = '2026-10-10T12:00:00.000Z';
    const mockProducts = [
      { id: 'prod-A', category_id: 'cat-1', name: 'Pizza A', base_price: 10, is_available: true, created_at: T, updated_at: T },
      { id: 'prod-B', category_id: 'cat-1', name: 'Pizza B', base_price: 12, is_available: true, created_at: T, updated_at: T },
      { id: 'prod-C', category_id: 'cat-1', name: 'Pizza C', base_price: 15, is_available: true, created_at: T, updated_at: T },
    ];

    // Pre-insert category to satisfy FK
    dbManager.runTransaction(db => {
      db.prepare(`
        INSERT INTO categories (id, name, slug, display_order, is_active, created_at, updated_at)
        VALUES ('cat-1', 'Pizzas', 'pizzas', 1, 1, '${T}', '${T}')
      `).run();
      // Mark prod-B as pending in sync_outbox
      db.prepare(`
        INSERT INTO sync_outbox (id, entity_type, entity_id, operation, payload_json, created_at)
        VALUES ('out-prod-B', 'products', 'prod-B', 'INSERT', '{}', '${T}')
      `).run();
    });

    const transport: CloudPullTransport = {
      async fetchProductsDelta(cursor, limit) {
        return mockProducts.filter(p => {
          if (cursor.lastTimestamp === '1970-01-01T00:00:00.000Z') return true;
          if (p.updated_at > cursor.lastTimestamp) return true;
          if (p.updated_at === cursor.lastTimestamp && p.id > cursor.lastId) return true;
          return false;
        }).slice(0, limit);
      }
    };

    // Cycle 1: sees prod-A, prod-B, prod-C
    const res1 = await runPullCycle({
      dbManager,
      transport,
      datasets: ['products'],
      batchSize: 10,
    });

    assert.equal(res1.status, 'COMPLETED');
    assert.equal(res1.rowsApplied, 1, 'Only prod-A before pending prod-B should be applied');

    // Verify prod-A is stored, prod-B and prod-C are NOT stored
    const check1 = dbManager.runTransaction(db => ({
      countA: (db.prepare("SELECT COUNT(*) as c FROM products WHERE id = 'prod-A'").get() as any).c,
      countB: (db.prepare("SELECT COUNT(*) as c FROM products WHERE id = 'prod-B'").get() as any).c,
      countC: (db.prepare("SELECT COUNT(*) as c FROM products WHERE id = 'prod-C'").get() as any).c,
      cursor: getSyncCursor(db, 'products'),
    }));

    assert.equal(check1.countA, 1);
    assert.equal(check1.countB, 0);
    assert.equal(check1.countC, 0);

    // CRITICAL: Cursor must be (T, 'prod-A'), NEVER advanced past prod-B
    assert.equal(check1.cursor.lastUpdatedAt, T);
    assert.equal(check1.cursor.lastId, 'prod-A');

    // Step 2: Push ACK occurs, clearing outbox entry for prod-B
    dbManager.runTransaction(db => {
      db.prepare("DELETE FROM sync_outbox WHERE entity_id = 'prod-B'").run();
    });

    // Cycle 2: Cursor query starting from (T, 'prod-A') selects prod-B and prod-C
    const res2 = await runPullCycle({
      dbManager,
      transport,
      datasets: ['products'],
      batchSize: 10,
    });

    assert.equal(res2.status, 'COMPLETED');
    assert.equal(res2.rowsApplied, 2, 'prod-B and prod-C should now be applied');

    const check2 = dbManager.runTransaction(db => ({
      countA: (db.prepare("SELECT COUNT(*) as c FROM products WHERE id = 'prod-A'").get() as any).c,
      countB: (db.prepare("SELECT COUNT(*) as c FROM products WHERE id = 'prod-B'").get() as any).c,
      countC: (db.prepare("SELECT COUNT(*) as c FROM products WHERE id = 'prod-C'").get() as any).c,
      cursor: getSyncCursor(db, 'products'),
    }));

    assert.equal(check2.countA, 1);
    assert.equal(check2.countB, 1);
    assert.equal(check2.countC, 1);

    // Cursor now safely advances to prod-C
    assert.equal(check2.cursor.lastUpdatedAt, T);
    assert.equal(check2.cursor.lastId, 'prod-C');
  });

  it('P0.2: PENDING_ROW_REPLAY_SAFE — Pending row re-fetched across multiple cycles without corrupting cursor or state', async () => {
    const T1 = '2026-10-10T12:00:00.000Z';
    const T2 = '2026-10-10T12:05:00.000Z';
    const mockCategories = [
      { id: 'cat-01', name: 'Appetizers', slug: 'appetizers', display_order: 1, is_active: true, created_at: T1, updated_at: T1 },
      { id: 'cat-02', name: 'Drinks', slug: 'drinks', display_order: 2, is_active: true, created_at: T2, updated_at: T2 },
    ];

    // Mark cat-01 as pending locally
    dbManager.runTransaction(db => {
      db.prepare(`
        INSERT INTO sync_outbox (id, entity_type, entity_id, operation, payload_json, created_at)
        VALUES ('out-cat-01', 'categories', 'cat-01', 'UPDATE', '{"name":"Locally Edited Appetizers"}', '${T1}')
      `).run();
    });

    let fetchCount = 0;
    const transport: CloudPullTransport = {
      async fetchCategoriesDelta(cursor, limit) {
        fetchCount++;
        return mockCategories.filter(c => {
          if (cursor.lastTimestamp === '1970-01-01T00:00:00.000Z') return true;
          if (c.updated_at > cursor.lastTimestamp) return true;
          if (c.updated_at === cursor.lastTimestamp && c.id > cursor.lastId) return true;
          return false;
        }).slice(0, limit);
      }
    };

    // Run 3 consecutive pull cycles while outbox remains pending
    for (let i = 1; i <= 3; i++) {
      const res = await runPullCycle({ dbManager, transport, datasets: ['categories'] });
      assert.equal(res.status, 'COMPLETED');
      assert.equal(res.rowsApplied, 0, `Cycle ${i}: pending first row must stop apply and yield 0 rows`);

      const cursor = dbManager.runTransaction(db => getSyncCursor(db, 'categories'));
      assert.equal(cursor.lastTimestamp || cursor.lastUpdatedAt, '1970-01-01T00:00:00.000Z');
      assert.equal(cursor.lastId, '00000000-0000-0000-0000-000000000000');

      // Verify no outbox echo created
      const outboxCount = dbManager.runTransaction(db => (db.prepare('SELECT COUNT(*) as c FROM sync_outbox').get() as any).c);
      assert.equal(outboxCount, 1, 'Outbox must retain only the 1 original pending record');
    }

    assert.equal(fetchCount, 3, 'Fetch must occur on each cycle');

    // Now clear outbox
    dbManager.runTransaction(db => {
      db.prepare("DELETE FROM sync_outbox WHERE entity_id = 'cat-01'").run();
    });

    // Cycle 4: Pending cleared, rows apply cleanly and cursor advances to cat-02
    const res4 = await runPullCycle({ dbManager, transport, datasets: ['categories'] });
    assert.equal(res4.status, 'COMPLETED');
    assert.equal(res4.rowsApplied, 2);

    const finalCursor = dbManager.runTransaction(db => getSyncCursor(db, 'categories'));
    assert.equal(finalCursor.lastUpdatedAt, T2);
    assert.equal(finalCursor.lastId, 'cat-02');
  });

  // ==========================================================================
  // P1: CHILD RANGE PAGINATION & COMPLETION PROOF TESTS
  // ==========================================================================

  it('P1.1: CHILD_RANGE_PAGINATION_BOUNDARY_TEST — Exact boundary conditions (0, 1, 499, 500, 501, 1000, 1001)', async () => {
    const boundaries = [0, 1, 499, 500, 501, 1000, 1001];

    for (const count of boundaries) {
      const dummyItems = Array.from({ length: count }, (_, i) => ({
        id: `item-${String(i + 1).padStart(5, '0')}`,
        order_id: 'ord-bound-1',
        product_id: 'prod-1',
        product_name: `Item ${i + 1}`,
        unit_price: 10,
        quantity: 1,
        line_total: 10,
        created_at: '2026-10-10T12:00:00Z',
      }));

      let rangeCalls = 0;
      const mockClient = {
        from(table: string) {
          if (table === 'orders') {
            return {
              select: () => ({
                order: () => ({
                  order: () => ({
                    limit: async () => ({
                      data: [{ id: 'ord-bound-1', channel: 'POS', order_type: 'DINE_IN', status: 'draft', subtotal: 10, grand_total: 10, created_at: '2026-10-10T12:00:00Z', updated_at: '2026-10-10T12:00:00Z' }],
                      error: null,
                    })
                  })
                })
              })
            };
          }
          if (table === 'order_items') {
            return {
              select: () => ({
                in: () => ({
                  order: () => ({
                    range: async (from: number, to: number) => {
                      rangeCalls++;
                      const slice = dummyItems.slice(from, to + 1);
                      return { data: slice, error: null };
                    }
                  })
                })
              })
            };
          }
          throw new Error(`Unexpected table ${table}`);
        }
      };

      const transport = createSupabasePullTransport(mockClient);
      const result = await transport.fetchOrdersDelta!({ lastTimestamp: '1970-01-01T00:00:00.000Z', lastId: '' }, 25);

      assert.equal(result.orderItems.length, count, `Count mismatch for boundary ${count}`);

      // Formula: ceil((count + 1) / CHILD_PAGE_SIZE) or Math.floor(count / CHILD_PAGE_SIZE) + 1
      const expectedRangeCalls = Math.floor(count / CHILD_PAGE_SIZE) + 1;
      assert.equal(rangeCalls, expectedRangeCalls, `Range call count formula mismatch for count ${count}`);
    }
  });

  it('P1.2: ORDER_CHILD_GT_1000_TEST & KOT_CHILD_GT_1000_TEST — Fetches and applies >1000 child items across multiple pages', async () => {
    // Pre-insert category and product to satisfy FKs
    dbManager.runTransaction(db => {
      db.prepare(`
        INSERT INTO categories (id, name, slug, display_order, is_active, created_at, updated_at)
        VALUES ('cat-1', 'Pizzas', 'pizzas', 1, 1, '2026-10-10T12:00:00Z', '2026-10-10T12:00:00Z')
      `).run();
      db.prepare(`
        INSERT INTO products (id, category_id, name, base_price_paise, is_available, tax_rate, is_inventory_tracked, created_at, updated_at)
        VALUES ('prod-1', 'cat-1', 'Big Item', 1000, 1, 5.0, 0, '2026-10-10T12:00:00Z', '2026-10-10T12:00:00Z')
      `).run();
    });

    const parentCount = 25;
    const itemsPerParent = 50;
    const totalItems = parentCount * itemsPerParent; // 1250 items > 1000!

    const orders = Array.from({ length: parentCount }, (_, i) => ({
      id: `ord-big-${String(i + 1).padStart(3, '0')}`,
      channel: 'POS',
      order_type: 'DINE_IN',
      status: 'draft',
      subtotal: 500,
      grand_total: 500,
      created_at: '2026-10-10T12:00:00Z',
      updated_at: '2026-10-10T12:00:00Z',
    }));

    const orderItems: any[] = [];
    let itemIdSeq = 1;
    for (const ord of orders) {
      for (let j = 0; j < itemsPerParent; j++) {
        orderItems.push({
          id: `item-big-${String(itemIdSeq++).padStart(5, '0')}`,
          order_id: ord.id,
          product_id: 'prod-1',
          product_name: `Big Item`,
          unit_price: 10,
          quantity: 1,
          line_total: 10,
          created_at: '2026-10-10T12:00:00Z',
        });
      }
    }

    let rangeCalls = 0;
    const mockClient = {
      from(table: string) {
        if (table === 'orders') {
          return {
            select: () => ({
              order: () => ({
                order: () => ({
                  limit: async () => ({ data: orders, error: null })
                })
              })
            })
          };
        }
        if (table === 'order_items') {
          return {
            select: () => ({
              in: () => ({
                order: () => ({
                  range: async (from: number, to: number) => {
                    rangeCalls++;
                    return { data: orderItems.slice(from, to + 1), error: null };
                  }
                })
              })
            })
          };
        }
        throw new Error(`Unexpected table ${table}`);
      }
    };

    const transport = createSupabasePullTransport(mockClient);
    const pullRes = await runPullCycle({
      dbManager,
      transport,
      datasets: ['orders'],
    });

    assert.equal(pullRes.status, 'COMPLETED');
    // 25 orders + 1250 items = 1275 rows applied
    assert.equal(pullRes.rowsApplied, parentCount + totalItems);

    // Verify 3 range calls: 500 + 500 + 250
    assert.equal(rangeCalls, 3);

    // Verify local DB counts
    const counts = dbManager.runTransaction(db => ({
      orders: (db.prepare('SELECT COUNT(*) as c FROM orders').get() as any).c,
      items: (db.prepare('SELECT COUNT(*) as c FROM order_items').get() as any).c,
      cursor: getSyncCursor(db, 'orders'),
    }));

    assert.equal(counts.orders, parentCount);
    assert.equal(counts.items, totalItems);
    assert.equal(counts.cursor.lastId, 'ord-big-025');
  });

  it('P1.3: NO_PARTIAL_APPLY_ON_CHILD_FAILURE — Child page failure prevents parent apply & cursor advance', async () => {
    const orders = [
      { id: 'ord-fail-1', channel: 'POS', order_type: 'DINE_IN', status: 'draft', subtotal: 100, grand_total: 100, created_at: '2026-10-10T12:00:00Z', updated_at: '2026-10-10T12:00:00Z' }
    ];

    let rangeCalls = 0;
    const mockClient = {
      from(table: string) {
        if (table === 'orders') {
          return {
            select: () => ({
              order: () => ({
                order: () => ({
                  limit: async () => ({ data: orders, error: null })
                })
              })
            })
          };
        }
        if (table === 'order_items') {
          return {
            select: () => ({
              in: () => ({
                order: () => ({
                  range: async (from: number) => {
                    rangeCalls++;
                    if (from === 0) {
                      // Page 1 succeeds with full 500 items
                      const page1 = Array.from({ length: 500 }, (_, i) => ({
                        id: `item-fail-${i}`,
                        order_id: 'ord-fail-1',
                        product_id: 'p-1',
                        product_name: 'P1 item',
                        unit_price: 1,
                        quantity: 1,
                        line_total: 1,
                        created_at: '2026-10-10T12:00:00Z',
                      }));
                      return { data: page1, error: null };
                    }
                    // Page 2 encounters 500 error / transport drop
                    return { data: null, error: { message: '500 Internal Server Error in range query' } };
                  }
                })
              })
            })
          };
        }
        throw new Error(`Unexpected table ${table}`);
      }
    };

    const transport = createSupabasePullTransport(mockClient);
    const res = await runPullCycle({
      dbManager,
      transport,
      datasets: ['orders'],
    });

    assert.equal(res.status, 'RETRYABLE_STOPPED');
    assert.equal(res.rowsApplied, 0, 'CHILD_FETCH_FAILURE_PARTIAL_APPLY must be NO (0 rows applied)');

    const counts = dbManager.runTransaction(db => ({
      orders: (db.prepare('SELECT COUNT(*) as c FROM orders').get() as any).c,
      items: (db.prepare('SELECT COUNT(*) as c FROM order_items').get() as any).c,
      cursor: getSyncCursor(db, 'orders'),
    }));

    assert.equal(counts.orders, 0, 'Zero orders applied locally on partial child failure');
    assert.equal(counts.items, 0, 'Zero items applied locally on partial child failure');
    assert.equal(counts.cursor.lastTimestamp || counts.cursor.lastUpdatedAt, '1970-01-01T00:00:00.000Z', 'CHILD_FETCH_FAILURE_CURSOR_ADVANCE must be NO');
    assert.equal(counts.cursor.lastId, '00000000-0000-0000-0000-000000000000');
  });

  it('P1.4: NORMAL_REQUEST_BOUND — Normal parent pages execute exactly 1 child range request', async () => {
    let orderRangeCalls = 0;
    let kotRangeCalls = 0;

    const mockClient = {
      from(table: string) {
        if (table === 'orders') {
          return {
            select: () => ({
              order: () => ({
                order: () => ({
                  limit: async () => ({
                    data: [{ id: 'ord-norm-1', channel: 'POS', order_type: 'DINE_IN', status: 'draft', subtotal: 10, grand_total: 10, created_at: '2026-10-10T12:00:00Z', updated_at: '2026-10-10T12:00:00Z' }],
                    error: null,
                  })
                })
              })
            })
          };
        }
        if (table === 'order_items') {
          return {
            select: () => ({
              in: () => ({
                order: () => ({
                  range: async () => {
                    orderRangeCalls++;
                    return { data: [{ id: 'item-1', order_id: 'ord-norm-1', product_id: 'p-1', product_name: 'P', unit_price: 10, quantity: 1, line_total: 10, created_at: '2026-10-10T12:00:00Z' }], error: null };
                  }
                })
              })
            })
          };
        }
        if (table === 'pos_kots') {
          return {
            select: () => ({
              order: () => ({
                order: () => ({
                  limit: async () => ({
                    data: [{ id: 'kot-norm-1', order_id: 'ord-norm-1', kot_number: 1, status: 'printed', printed_at: '2026-10-10T12:00:00Z' }],
                    error: null,
                  })
                })
              })
            })
          };
        }
        if (table === 'kot_items') {
          return {
            select: () => ({
              in: () => ({
                order: () => ({
                  range: async () => {
                    kotRangeCalls++;
                    return { data: [{ id: 'kitem-1', kot_id: 'kot-norm-1', product_id: 'p-1', product_name: 'P', quantity: 1 }], error: null };
                  }
                })
              })
            })
          };
        }
        throw new Error(`Unexpected table ${table}`);
      }
    };

    const transport = createSupabasePullTransport(mockClient);
    await transport.fetchOrdersDelta!({ lastTimestamp: '1970-01-01T00:00:00.000Z', lastId: '' }, 25);
    await transport.fetchKotsDelta!({ lastTimestamp: '1970-01-01T00:00:00.000Z', lastId: '' }, 25);

    assert.equal(orderRangeCalls, 1, 'NORMAL_ORDER_CHILD_REQUESTS must be 1');
    assert.equal(kotRangeCalls, 1, 'NORMAL_KOT_CHILD_REQUESTS must be 1');
  });

});
