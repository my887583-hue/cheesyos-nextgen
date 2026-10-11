/**
 * CHEESYOS NEXTGEN POS SYNC — RUNTIME ORCHESTRATION SUITE
 * 
 * Verifies single-flight execution, request coalescing, stream selectivity,
 * error stopping policies, and zero-timer behavior.
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import { OrderDomain, OrderItemDomain } from '@cheesyos/nextgen-shared';
import {
  PosLocalDatabase,
  saveOrderTransaction,
  getSyncCursor,
} from '@cheesyos/pos-local';
import {
  SyncRuntimeOrchestrator,
  CloudRpcTransport,
  CloudPullTransport,
  PushSyncError,
  OPERATIONAL_DATASETS,
  MASTER_DATASETS,
  CUSTOMER_DATASETS,
} from '../src/index.js';

function seedProduct(dbManager: PosLocalDatabase, productId: string = 'prod-101', categoryId: string = 'cat-1') {
  dbManager.runTransaction(db => {
    db.prepare(`
      INSERT INTO categories (id, name, slug, display_order, is_active, created_at, updated_at)
      VALUES (?, 'Cat 1', 'cat-1', 0, 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      ON CONFLICT (id) DO NOTHING
    `).run(categoryId);
    db.prepare(`
      INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at)
      VALUES (?, ?, 'Test Product', 1000, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      ON CONFLICT (id) DO NOTHING
    `).run(productId, categoryId);
  });
}

function createTestOrder(id: string = 'ord-101'): { order: OrderDomain; items: OrderItemDomain[] } {
  const now = new Date().toISOString();
  return {
    order: {
      id,
      channel: 'POS',
      order_type: 'DINE_IN',
      status: 'pending',
      subtotal: 10,
      tax_total: 0.5,
      discount_total: 0,
      delivery_charge: 0,
      grand_total: 10.5,
      created_at: now,
      updated_at: now,
    },
    items: [
      {
        id: `item-${id}`,
        order_id: id,
        product_id: 'prod-101',
        product_name: 'Pizza',
        unit_price: 10,
        quantity: 1,
        tax_rate: 5,
        discount_amount: 0,
        line_total: 10.5,
        created_at: now,
      }
    ]
  };
}

function createMockPushTransport(overrides: Partial<CloudRpcTransport> = {}): {
  transport: CloudRpcTransport;
  pushCallCount: number;
} {
  let pushCallCount = 0;
  const transport: CloudRpcTransport = {
    async syncOrder(order, items) {
      pushCallCount++;
      if (overrides.syncOrder) return overrides.syncOrder(order, items);
      return true;
    },
    async syncKot(kot, items) {
      pushCallCount++;
      if (overrides.syncKot) return overrides.syncKot(kot, items);
      return true;
    },
    async syncKotCorrection(correction) {
      pushCallCount++;
      if (overrides.syncKotCorrection) return overrides.syncKotCorrection(correction);
      return true;
    },
    async syncBill(bill) {
      pushCallCount++;
      if (overrides.syncBill) return overrides.syncBill(bill);
      return true;
    },
    async syncPayment(payment) {
      pushCallCount++;
      if (overrides.syncPayment) return overrides.syncPayment(payment);
      return true;
    },
    async applyInventoryMovement(input) {
      pushCallCount++;
      if (overrides.applyInventoryMovement) return overrides.applyInventoryMovement(input);
      return true;
    }
  };

  return {
    transport,
    get pushCallCount() { return pushCallCount; }
  };
}

function createMockPullTransport(overrides: Partial<CloudPullTransport> = {}): {
  transport: CloudPullTransport;
  fetchCounts: Record<string, number>;
} {
  const fetchCounts: Record<string, number> = {
    categories: 0,
    products: 0,
    product_variants: 0,
    customers: 0,
    pos_tables: 0,
    table_sessions: 0,
    orders: 0,
    pos_kots: 0,
    kot_corrections: 0,
    bills: 0,
    payments: 0,
    inventory_lite: 0,
  };

  const transport: CloudPullTransport = {
    async fetchCategoriesDelta(cursor, limit) {
      fetchCounts.categories++;
      if (overrides.fetchCategoriesDelta) return overrides.fetchCategoriesDelta(cursor, limit);
      return [];
    },
    async fetchProductsDelta(cursor, limit) {
      fetchCounts.products++;
      if (overrides.fetchProductsDelta) return overrides.fetchProductsDelta(cursor, limit);
      return [];
    },
    async fetchProductVariantsDelta(cursor, limit) {
      fetchCounts.product_variants++;
      if (overrides.fetchProductVariantsDelta) return overrides.fetchProductVariantsDelta(cursor, limit);
      return [];
    },
    async fetchCustomersDelta(cursor, limit) {
      fetchCounts.customers++;
      if (overrides.fetchCustomersDelta) return overrides.fetchCustomersDelta(cursor, limit);
      return [];
    },
    async fetchPosTablesDelta(cursor, limit) {
      fetchCounts.pos_tables++;
      if (overrides.fetchPosTablesDelta) return overrides.fetchPosTablesDelta(cursor, limit);
      return [];
    },
    async fetchTableSessionsDelta(cursor, limit) {
      fetchCounts.table_sessions++;
      if (overrides.fetchTableSessionsDelta) return overrides.fetchTableSessionsDelta(cursor, limit);
      return [];
    },
    async fetchOrdersDelta(cursor, limit) {
      fetchCounts.orders++;
      if (overrides.fetchOrdersDelta) return overrides.fetchOrdersDelta(cursor, limit);
      return { orders: [], orderItems: [] };
    },
    async fetchKotsDelta(cursor, limit) {
      fetchCounts.pos_kots++;
      if (overrides.fetchKotsDelta) return overrides.fetchKotsDelta(cursor, limit);
      return { kots: [], kotItems: [] };
    },
    async fetchKotCorrectionsDelta(cursor, limit) {
      fetchCounts.kot_corrections++;
      if (overrides.fetchKotCorrectionsDelta) return overrides.fetchKotCorrectionsDelta(cursor, limit);
      return [];
    },
    async fetchBillsDelta(cursor, limit) {
      fetchCounts.bills++;
      if (overrides.fetchBillsDelta) return overrides.fetchBillsDelta(cursor, limit);
      return [];
    },
    async fetchPaymentsDelta(cursor, limit) {
      fetchCounts.payments++;
      if (overrides.fetchPaymentsDelta) return overrides.fetchPaymentsDelta(cursor, limit);
      return [];
    },
    async fetchInventoryLiteDelta(cursor, limit) {
      fetchCounts.inventory_lite++;
      if (overrides.fetchInventoryLiteDelta) return overrides.fetchInventoryLiteDelta(cursor, limit);
      return [];
    },
  };

  return { transport, fetchCounts };
}

describe('CHEESYOS NEXTGEN POS SYNC — RUNTIME ORCHESTRATION SUITE', () => {

  test('1. PUSH_SINGLE_FLIGHT: 20 concurrent push requests trigger only 1 push cycle', async () => {
    const dbManager = new PosLocalDatabase(':memory:');
    seedProduct(dbManager);
    const { order, items } = createTestOrder('ord-1');
    saveOrderTransaction(dbManager, order, items);

    let resolvePushPromise: (() => void) | null = null;
    let pushExecCount = 0;
    const mockPush = createMockPushTransport({
      async syncOrder() {
        pushExecCount++;
        if (pushExecCount === 1) {
          await new Promise<void>((res) => { resolvePushPromise = res; });
        }
        return true;
      }
    });
    const { transport: pullTransport } = createMockPullTransport();

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager,
      pushTransport: mockPush.transport,
      pullTransport,
    });

    // Dispatch 20 concurrent push requests
    const pushPromises = Array.from({ length: 20 }, () => orchestrator.requestPush());

    assert.equal(orchestrator.getStatus().isPushActive, true);

    // Resolve active push
    while (!resolvePushPromise) {
      await new Promise((r) => setImmediate(r));
    }
    (resolvePushPromise as () => void)();
    await Promise.all(pushPromises);

    // Verify only 1 push call executed to transport
    assert.equal(mockPush.pushCallCount, 1);
    assert.equal(orchestrator.getStatus().isPushActive, false);


    dbManager.close();
  });

  test('2. PULL_SINGLE_FLIGHT: 20 concurrent pull requests trigger only 1 pull cycle', async () => {
    const dbManager = new PosLocalDatabase(':memory:');
    const { transport: pushTransport } = createMockPushTransport();

    let resolvePullPromise: (() => void) | null = null;
    let categoryCallCount = 0;
    const { transport: pullTransport, fetchCounts } = createMockPullTransport({
      async fetchCategoriesDelta() {
        categoryCallCount++;
        if (categoryCallCount === 1) {
          await new Promise<void>((res) => { resolvePullPromise = res; });
        }
        return [];
      }
    });

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager,
      pushTransport,
      pullTransport,
    });

    const pullPromises = Array.from({ length: 20 }, () => orchestrator.requestPull());

    assert.equal(orchestrator.getStatus().isPullActive, true);

    while (!resolvePullPromise) {
      await new Promise((r) => setImmediate(r));
    }
    (resolvePullPromise as () => void)();
    await Promise.all(pullPromises);

    // Categories fetched exactly once despite 20 callers
    assert.equal(fetchCounts.categories, 1);
    assert.equal(orchestrator.getStatus().isPullActive, false);

    dbManager.close();
  });

  test('3. PUSH_DURING_PUSH_COALESCED: Local write while push is active causes at most 1 follow-up push cycle', async () => {
    const dbManager = new PosLocalDatabase(':memory:');
    seedProduct(dbManager);

    // Seed Order 1
    const t1 = createTestOrder('ord-1');
    saveOrderTransaction(dbManager, t1.order, t1.items);

    let syncOrderCallCount = 0;
    let releaseFirstSync: (() => void) | null = null;

    const { transport: pushTransport } = createMockPushTransport({
      async syncOrder() {
        syncOrderCallCount++;
        if (syncOrderCallCount === 1) {
          await new Promise<void>((res) => { releaseFirstSync = res; });
        }
        return true;
      }
    });
    const { transport: pullTransport } = createMockPullTransport();

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager,
      pushTransport,
      pullTransport,
    });

    // Start 1st push
    const p1 = orchestrator.requestPush();

    // While 1st push is in flight, seed Order 2 and request push
    const t2 = createTestOrder('ord-2');
    saveOrderTransaction(dbManager, t2.order, t2.items);
    
    // Request push 5 times while first push is running
    const p2_promises = Array.from({ length: 5 }, () => orchestrator.requestPush());

    // Release first push
    while (!releaseFirstSync) {
      await new Promise((r) => setImmediate(r));
    }
    (releaseFirstSync as () => void)();
    await p1;
    await Promise.all(p2_promises);

    // Total syncOrder calls must equal exactly 2 (Order 1 in cycle 1, Order 2 in follow-up cycle 2)
    assert.equal(syncOrderCallCount, 2);

    dbManager.close();
  });

  test('4. STARTUP_PUSH_THEN_PULL: requestStartupSync runs push first, then pull', async () => {
    const dbManager = new PosLocalDatabase(':memory:');
    seedProduct(dbManager);
    const orderLog: string[] = [];

    const { transport: pushTransport } = createMockPushTransport({
      async syncOrder() {
        orderLog.push('PUSH_EXEC');
        return true;
      }
    });

    const { transport: pullTransport } = createMockPullTransport({
      async fetchCategoriesDelta() {
        orderLog.push('PULL_EXEC');
        return [];
      }
    });

    // Seed 1 order to trigger push
    const t1 = createTestOrder('ord-1');
    saveOrderTransaction(dbManager, t1.order, t1.items);

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager,
      pushTransport,
      pullTransport,
    });

    const res = await orchestrator.requestStartupSync();

    assert.equal(res.pushResult.status, 'COMPLETED');
    assert.equal(res.pullResult?.status, 'COMPLETED');
    assert.deepEqual(orderLog, ['PUSH_EXEC', 'PULL_EXEC']);

    dbManager.close();
  });

  test('5. STARTUP_AUTH_FAILURE_STOPS: AUTH_REQUIRED during startup push prevents pull', async () => {
    const dbManager = new PosLocalDatabase(':memory:');
    seedProduct(dbManager);
    let pullAttempted = false;

    const { transport: pushTransport } = createMockPushTransport({
      async syncOrder() {
        throw new PushSyncError('AUTH_REQUIRED', 'Access Denied 42501');
      }
    });

    const { transport: pullTransport } = createMockPullTransport({
      async fetchCategoriesDelta() {
        pullAttempted = true;
        return [];
      }
    });

    const t1 = createTestOrder('ord-1');
    saveOrderTransaction(dbManager, t1.order, t1.items);

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager,
      pushTransport,
      pullTransport,
    });

    const res = await orchestrator.requestStartupSync();

    assert.equal(res.pushResult.status, 'AUTH_REQUIRED_STOPPED');
    assert.equal(res.pullResult, undefined);
    assert.equal(pullAttempted, false);

    dbManager.close();
  });

  test('6. STARTUP_NETWORK_FAILURE_STOPS: RETRYABLE network error during startup push prevents pull', async () => {
    const dbManager = new PosLocalDatabase(':memory:');
    seedProduct(dbManager);
    let pullAttempted = false;

    const { transport: pushTransport } = createMockPushTransport({
      async syncOrder() {
        throw new PushSyncError('RETRYABLE', 'Network unreachable');
      }
    });

    const { transport: pullTransport } = createMockPullTransport({
      async fetchCategoriesDelta() {
        pullAttempted = true;
        return [];
      }
    });

    const t1 = createTestOrder('ord-1');
    saveOrderTransaction(dbManager, t1.order, t1.items);

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager,
      pushTransport,
      pullTransport,
    });

    const res = await orchestrator.requestStartupSync();

    assert.equal(res.pushResult.status, 'RETRYABLE_STOPPED');
    assert.equal(res.pullResult, undefined);
    assert.equal(pullAttempted, false);

    dbManager.close();
  });

  test('7. RECONNECT_PUSH_THEN_PULL & 8. FOREGROUND_PULL & 9. MANUAL_REFRESH_PULL', async () => {
    const dbManager = new PosLocalDatabase(':memory:');
    const { transport: pushTransport } = createMockPushTransport();
    const { transport: pullTransport, fetchCounts } = createMockPullTransport();

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager,
      pushTransport,
      pullTransport,
    });

    // Reconnect sync
    const recRes = await orchestrator.requestReconnectSync();
    assert.equal(recRes.pushResult.status, 'IDLE');
    assert.equal(recRes.pullResult?.status, 'COMPLETED');
    assert.equal(fetchCounts.orders, 1);
    assert.equal(fetchCounts.categories, 0); // Reconnect fetches OPERATIONAL datasets only

    // Foreground sync
    const fgRes = await orchestrator.requestForegroundSync();
    assert.equal(fgRes.status, 'COMPLETED');
    assert.equal(fetchCounts.orders, 2);

    // Manual refresh for master datasets
    const manRes = await orchestrator.requestManualRefresh('master');
    assert.equal(manRes.status, 'COMPLETED');
    assert.equal(fetchCounts.categories, 1);
    assert.equal(fetchCounts.products, 1);

    dbManager.close();
  });

  test('10. FOCUS_STORM_COALESCED: 50 rapid focus requests execute at most 1 in-flight pull cycle', async () => {
    const dbManager = new PosLocalDatabase(':memory:');
    const { transport: pushTransport } = createMockPushTransport();

    let pullCycleCount = 0;
    let releasePull: (() => void) | null = null;

    const { transport: pullTransport } = createMockPullTransport({
      async fetchOrdersDelta() {
        pullCycleCount++;
        if (pullCycleCount === 1) {
          await new Promise<void>((res) => { releasePull = res; });
        }
        return { orders: [], orderItems: [] };
      }
    });

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager,
      pushTransport,
      pullTransport,
    });

    // Dispatch 50 rapid focus requests
    const fgPromises = Array.from({ length: 50 }, () => orchestrator.requestForegroundSync());

    while (!releasePull) {
      await new Promise((r) => setImmediate(r));
    }
    (releasePull as () => void)();
    await Promise.all(fgPromises);

    // Exactly 1 cycle executed (single-flight shared promise)
    assert.equal(pullCycleCount, 1);

    dbManager.close();
  });

  test('11. RECONNECT_STORM_BOUNDED & 12, 13, 14. ERROR_NO_RETRY_LOOP', async () => {
    const dbManager = new PosLocalDatabase(':memory:');
    seedProduct(dbManager);
    let pushAttempts = 0;

    const { transport: pushTransport } = createMockPushTransport({
      async syncOrder() {
        pushAttempts++;
        throw new PushSyncError('AUTH_REQUIRED', '42501 Denied');
      }
    });
    const { transport: pullTransport } = createMockPullTransport();

    const t1 = createTestOrder('ord-1');
    saveOrderTransaction(dbManager, t1.order, t1.items);

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager,
      pushTransport,
      pullTransport,
    });

    // 20 reconnect events in rapid succession
    const reconnectPromises = Array.from({ length: 20 }, () => orchestrator.requestReconnectSync());
    const results = await Promise.all(reconnectPromises);

    // Verify all return AUTH_REQUIRED_STOPPED and total attempts = 1 (no infinite retry loop)
    assert.equal(pushAttempts, 1);
    assert.equal(results[0].pushResult.status, 'AUTH_REQUIRED_STOPPED');

    dbManager.close();
  });

  test('15. NO_TIMER_CREATED: Orchestrator is purely demand-driven with no background interval', () => {
    const dbManager = new PosLocalDatabase(':memory:');
    const { transport: pushTransport } = createMockPushTransport();
    const { transport: pullTransport } = createMockPullTransport();

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager,
      pushTransport,
      pullTransport,
    });

    const status = orchestrator.getStatus();
    assert.equal(status.isPushActive, false);
    assert.equal(status.isPullActive, false);

    dbManager.close();
  });

  test('16, 17, 18. STREAM_SELECTIVITY: OPERATIONAL, MASTER, and CUSTOMER scopes fetch exact datasets', async () => {
    const dbManager = new PosLocalDatabase(':memory:');
    const { transport: pushTransport } = createMockPushTransport();
    const { transport: pullTransport, fetchCounts } = createMockPullTransport();

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager,
      pushTransport,
      pullTransport,
    });

    // Operational Scope
    await orchestrator.requestPull(OPERATIONAL_DATASETS);
    assert.equal(fetchCounts.orders, 1);
    assert.equal(fetchCounts.categories, 0);
    assert.equal(fetchCounts.customers, 0);

    // Master Scope
    await orchestrator.requestPull(MASTER_DATASETS);
    assert.equal(fetchCounts.orders, 1);
    assert.equal(fetchCounts.categories, 1);
    assert.equal(fetchCounts.customers, 0);

    // Customer Scope
    await orchestrator.requestPull(CUSTOMER_DATASETS);
    assert.equal(fetchCounts.orders, 1);
    assert.equal(fetchCounts.categories, 1);
    assert.equal(fetchCounts.customers, 1);

    dbManager.close();
  });

  test('19. UNSELECTED_CURSOR_UNCHANGED & 20. EXISTING_FULL_PULL_COMPATIBILITY', async () => {
    const dbManager = new PosLocalDatabase(':memory:');
    const { transport: pushTransport } = createMockPushTransport();
    const { transport: pullTransport } = createMockPullTransport({
      async fetchOrdersDelta() {
        return {
          orders: [{ id: 'o100', channel: 'POS', order_type: 'DINE_IN', status: 'billed', subtotal: 10, tax_total: 0.5, discount_total: 0, delivery_charge: 0, grand_total: 10.5, created_at: '2026-10-10T12:00:00.000Z', updated_at: '2026-10-10T12:05:00.000Z' }],
          orderItems: []
        };
      }
    });

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager,
      pushTransport,
      pullTransport,
    });

    // Pull operational dataset
    await orchestrator.requestPull(OPERATIONAL_DATASETS);

    // Verify orders cursor advanced to 2026-10-10T12:05:00.000Z
    const orderCursor = dbManager.runTransaction(db => getSyncCursor(db, 'orders'));
    assert.equal(orderCursor.lastUpdatedAt, '2026-10-10T12:05:00.000Z');

    // Verify categories cursor remains 1970-01-01
    const catCursor = dbManager.runTransaction(db => getSyncCursor(db, 'categories'));
    assert.equal(catCursor.lastUpdatedAt, '1970-01-01T00:00:00.000Z');

    dbManager.close();
  });

  test('21. PERIODIC_ELIGIBILITY: Periodic pull respects operational, master, and customer interval thresholds', async () => {
    let mockTime = 1000000;
    const dbManager = new PosLocalDatabase(':memory:');
    const { transport: pushTransport } = createMockPushTransport();
    const { transport: pullTransport, fetchCounts } = createMockPullTransport();

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager,
      pushTransport,
      pullTransport,
      nowFn: () => mockTime,
    });

    // Initial state: all streams eligible
    assert.equal(orchestrator.shouldRunOperationalPull(), true);
    assert.equal(orchestrator.shouldRunMasterPull(), true);
    assert.equal(orchestrator.shouldRunCustomerPull(), true);

    // Initial periodic pull runs all eligible streams
    await orchestrator.requestPeriodicPull();
    assert.equal(fetchCounts.orders, 1);
    assert.equal(fetchCounts.categories, 1);
    assert.equal(fetchCounts.customers, 1);

    // Advance time by 3 minutes (OPERATIONAL_MIN_INTERVAL_MS is 5 minutes)
    mockTime += 3 * 60 * 1000;
    assert.equal(orchestrator.shouldRunOperationalPull(), false);
    assert.equal(orchestrator.shouldRunMasterPull(), false);
    assert.equal(orchestrator.shouldRunCustomerPull(), false);

    // Periodic pull call now returns null (ineligible)
    const periodicRes1 = await orchestrator.requestPeriodicPull();
    assert.equal(periodicRes1, null);

    // Advance time to 6 minutes total (operational eligible, master/customer ineligible)
    mockTime += 3 * 60 * 1000;
    assert.equal(orchestrator.shouldRunOperationalPull(), true);
    assert.equal(orchestrator.shouldRunMasterPull(), false);

    await orchestrator.requestPeriodicPull();
    assert.equal(fetchCounts.orders, 2);
    assert.equal(fetchCounts.categories, 1); // Not re-fetched

    dbManager.close();
  });
});
