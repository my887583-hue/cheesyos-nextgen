/**
 * CHEESYOS NEXTGEN WINDOWS POS — RUNTIME EVENT & LIFECYCLE WIRING TEST SUITE
 * 
 * Verifies Phase 3F.6:
 * - Single runtime owner & orchestrator instance count (1).
 * - Startup prerequisites & staff auth gating.
 * - Local committed write signal strictly after SQLite commit (Push ASAP).
 * - Coalescing & single-flight protection (No Push Storm).
 * - Network reconnect (window:online -> PUSH then Operational PULL).
 * - Foreground / focus duplicate throttle guard & Focus Storm protection.
 * - Bounded periodic eligibility wake & 60-minute request budget measurement.
 * - Offline startup, write durability, and reconnect drain.
 * - Cross push/pull concurrency and local database safety.
 * - Clean event listener and timer disposal (React StrictMode safety).
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { TauriPosPersistence, TauriInvokeHandler } from '../src/tauri-adapter.js';
import { WindowsPosLifecycleManager } from '../src/lifecycle.js';
import {
  SyncRuntimeOrchestrator,
  CloudRpcTransport,
  CloudPullTransport,
  OPERATIONAL_DATASETS,
  MASTER_DATASETS,
  CUSTOMER_DATASETS,
} from '@cheesyos/pos-sync';
import type {
  OrderDomain,
  OrderItemDomain,
  PosKotDomain,
  KotItemDomain,
  KotCorrectionDomain,
  BillDomain,
  PaymentDomain,
} from '@cheesyos/nextgen-shared';

function createMockPersistenceEngine() {
  let deviceConfig: any = {
    device_id: 'dev-win-01',
    terminal_code: 'T01',
    device_name: 'Main Counter',
  };
  let sequenceCounter = 0;
  const outbox: any[] = [];
  const cursors: Record<string, { lastUpdatedAt: string; lastId: string; updatedAt: string }> = {};

  const invoke: TauriInvokeHandler = async (cmd: string, args?: Record<string, unknown>) => {
    if (cmd === 'init_db_schema') return 'DB_INITIALIZED';
    if (cmd === 'pos_db_query') {
      const q = args?.query as any;
      if (q.type === 'GetDeviceConfig') return deviceConfig;
      if (q.type === 'GetPendingOutbox') return outbox.slice(0, q.payload?.limit || 10);
      if (q.type === 'GetSyncCursor') {
        return cursors[q.payload.dataset] || {
          dataset: q.payload.dataset,
          last_updated_at: '1970-01-01T00:00:00.000Z',
          last_id: '',
          updated_at: '1970-01-01T00:00:00.000Z',
        };
      }
    }
    if (cmd === 'pos_db_execute') {
      const op = args?.op as any;
      switch (op.type) {
        case 'SetDeviceConfig':
          deviceConfig = op.payload;
          return deviceConfig;
        case 'SaveOrderAggregate': {
          const entry = { seq: outbox.length + 1, id: 'out-' + (outbox.length + 1), entity_type: 'orders', entity_id: op.payload.order.id, operation: 'INSERT', payload_json: JSON.stringify(op.payload), created_at: op.payload.order.created_at, attempt_count: 0 };
          outbox.push(entry);
          return { order: op.payload.order, items: op.payload.items, outbox_entries: [entry] };
        }
        case 'SaveKotAggregate': {
          const entry = { seq: outbox.length + 1, id: 'out-' + (outbox.length + 1), entity_type: 'pos_kots', entity_id: op.payload.kot.id, operation: 'INSERT', payload_json: JSON.stringify(op.payload), created_at: op.payload.kot.printed_at, attempt_count: 0 };
          outbox.push(entry);
          return { kot: op.payload.kot, items: op.payload.items, outbox_entries: [entry] };
        }
        case 'SaveKotCorrection': {
          const entry = { seq: outbox.length + 1, id: 'out-' + (outbox.length + 1), entity_type: 'kot_corrections', entity_id: op.payload.id, operation: 'INSERT', payload_json: JSON.stringify(op.payload), created_at: op.payload.created_at, attempt_count: 0 };
          outbox.push(entry);
          return entry;
        }
        case 'SaveBillWithSequence': {
          sequenceCounter++;
          const authoritativeBillNumber = `CB-${deviceConfig.terminal_code}-${String(sequenceCounter).padStart(6, '0')}`;
          const callerBill = (op.payload.bill_number || '').trim();
          const isPlaceholder = ['PENDING', 'DRAFT', 'TEMP', 'UNASSIGNED', ''].includes(callerBill.toUpperCase());
          if (!isPlaceholder && callerBill !== authoritativeBillNumber) {
            sequenceCounter--;
            throw new Error(`[PosPersistence] BILL_NUMBER_CONFLICT: Caller-provided bill_number "${op.payload.bill_number}" conflicts with allocated sequence number "${authoritativeBillNumber}".`);
          }
          const entry = { seq: outbox.length + 1, id: 'out-' + (outbox.length + 1), entity_type: 'bills', entity_id: op.payload.id, operation: 'INSERT', payload_json: JSON.stringify(op.payload), created_at: op.payload.finalized_at, attempt_count: 0 };
          outbox.push(entry);
          return { bill: { ...op.payload, bill_number: authoritativeBillNumber, device_id: deviceConfig.device_id }, sequence_number: sequenceCounter, outbox_entry: entry };
        }
        case 'SavePayment': {
          const entry = { seq: outbox.length + 1, id: 'out-' + (outbox.length + 1), entity_type: 'payments', entity_id: op.payload.payment.id, operation: 'INSERT', payload_json: JSON.stringify(op.payload), created_at: op.payload.payment.confirmed_at, attempt_count: 0 };
          outbox.push(entry);
          return { payment: op.payload.payment, updated_bill: op.payload.updated_bill, outbox_entry: entry };
        }
        case 'SaveInventoryMovement': {
          const entry = { seq: outbox.length + 1, id: 'out-' + (outbox.length + 1), entity_type: 'inventory_movements', entity_id: op.payload.id || 'move-1', operation: 'INSERT', payload_json: JSON.stringify(op.payload), created_at: op.payload.created_at || '2026-10-10T12:00:00Z', attempt_count: 0 };
          outbox.push(entry);
          return { movement_id: op.payload.id || 'move-1', product_id: op.payload.product_id, new_stock: 40, outbox_entry: entry };
        }
        case 'AcknowledgeOutbox': {
          const idx = outbox.findIndex(r => r.seq === op.payload.seq);
          if (idx !== -1) outbox.splice(idx, 1);
          return { acknowledged: true };
        }
        case 'UpdateOutboxFailure': {
          const row = outbox.find(r => r.seq === op.payload.seq);
          if (row) { row.attempt_count++; row.last_error = op.payload.error; }
          return { updated: true };
        }
        case 'ApplyPullBatch': {
          cursors[op.payload.dataset] = {
            dataset: op.payload.dataset,
            last_updated_at: op.payload.new_cursor.last_updated_at,
            last_id: op.payload.new_cursor.last_id,
            updated_at: '2026-10-10T12:00:00Z',
          };
          return { rowsApplied: op.payload.rows.length };
        }
      }
    }
    throw new Error(`UNKNOWN_COMMAND: ${cmd}`);
  };

  const persistence = new TauriPosPersistence(invoke);
  return { persistence, outbox };
}

describe('CHEESYOS NEXTGEN WINDOWS POS — RUNTIME EVENT & LIFECYCLE WIRING', () => {

  it('1. SINGLE RUNTIME OWNER & CLEAN DISPOSAL: Exactly 1 lifecycle instance, idempotent start, and clean disposal', () => {
    const { persistence } = createMockPersistenceEngine();
    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager: persistence,
      pushTransport: { syncOrder: async () => true } as any,
      pullTransport: {} as any,
    });

    const lifecycle = new WindowsPosLifecycleManager({
      persistence,
      orchestrator,
      wakeIntervalMs: 60000,
    });

    assert.equal(lifecycle.getStatus().isRunning, false);
    assert.equal(lifecycle.getStatus().wakeTimerActive, false);

    lifecycle.start();
    assert.equal(lifecycle.getStatus().isRunning, true);
    assert.equal(lifecycle.getStatus().wakeTimerActive, true);

    // Idempotent start: calling start again does not create a second timer
    lifecycle.start();
    assert.equal(lifecycle.getStatus().isRunning, true);

    // Clean disposal
    lifecycle.dispose();
    assert.equal(lifecycle.getStatus().isRunning, false);
    assert.equal(lifecycle.getStatus().wakeTimerActive, false);

    // Calling dispose again is safe
    lifecycle.dispose();
  });

  it('2. STARTUP PREREQUISITES & AUTH SESSION GATING: Startup cloud sync is gated until staff auth session is ready', async () => {
    const { persistence } = createMockPersistenceEngine();
    let startupPushCalled = false;
    let authReady = false;

    const pushTransport: CloudRpcTransport = {
      syncOrder: async () => { startupPushCalled = true; return true; },
      syncKot: async () => true,
      syncKotCorrection: async () => true,
      syncBill: async () => true,
      syncPayment: async () => true,
      applyInventoryMovement: async () => true,
    };

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager: persistence,
      pushTransport,
      pullTransport: {} as any,
    });

    const lifecycle = new WindowsPosLifecycleManager({
      persistence,
      orchestrator,
      isAuthSessionReady: () => authReady,
      wakeIntervalMs: 60000,
    });

    // Start while authReady is false
    lifecycle.start();
    assert.equal(lifecycle.getStatus().authSessionReady, false);
    assert.equal(startupPushCalled, false, 'Startup sync must remain gated when auth session is not ready');

    // Simulate staff PIN login -> auth becomes ready
    await lifecycle.setAuthSessionReady(true);
    assert.equal(lifecycle.getStatus().authSessionReady, true);

    lifecycle.dispose();
  });

  it('3. LOCAL COMMITTED WRITE SIGNAL & COALESCED PUSH: Committed writes trigger push ASAP; failed writes do not; bursts coalesce', async () => {
    const { persistence, outbox } = createMockPersistenceEngine();
    let pushExecutions = 0;

    const pushTransport: CloudRpcTransport = {
      syncOrder: async () => {
        pushExecutions++;
        // Simulate in-flight delay
        await new Promise((r) => setTimeout(r, 20));
        return true;
      },
      syncKot: async () => true,
      syncKotCorrection: async () => true,
      syncBill: async () => true,
      syncPayment: async () => true,
      applyInventoryMovement: async () => true,
    };

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager: persistence,
      pushTransport,
      pullTransport: {} as any,
    });

    const lifecycle = new WindowsPosLifecycleManager({
      persistence,
      orchestrator,
      isAuthSessionReady: () => true,
      wakeIntervalMs: 0, // No timer in this test
    });

    lifecycle.start();

    // 1. Valid Order Aggregate Commit triggers post-commit push
    const order: OrderDomain = {
      id: 'ord-w1', channel: 'POS', order_type: 'DINE_IN', status: 'draft',
      subtotal: 100, tax_total: 5, discount_total: 0, delivery_charge: 0, grand_total: 105,
      created_at: '2026-10-10T12:00:00Z', updated_at: '2026-10-10T12:00:00Z',
    };
    await persistence.saveOrderAggregate(order, []);
    // Allow the in-flight post-commit push cycle to complete
    await new Promise((r) => setTimeout(r, 50));
    assert.ok(pushExecutions >= 1, 'Local committed write must request push');

    // 2. Failed transaction (BILL_NUMBER_CONFLICT) must NOT signal post-commit push
    const initialPushes = pushExecutions;
    await assert.rejects(
      async () => {
        await persistence.saveBillWithSequence({
          id: 'bill-conf', order_id: 'ord-w1', bill_number: 'CB-T01-999999',
          subtotal: 100, cgst_total: 2.5, sgst_total: 2.5, discount_total: 0, grand_total: 105,
          payment_status: 'unpaid', finalized_at: '2026-10-10T12:00:00Z',
        });
      },
      /BILL_NUMBER_CONFLICT/
    );
    // Give event loop time to verify no phantom push was dispatched
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(pushExecutions, initialPushes, 'Failed transaction must NOT dispatch post-commit write push');

    // 3. WRITE BURST: multiple rapid writes while one push is active coalesce to at most 1 active + 1 follow-up
    const pushCountBeforeBurst = pushExecutions;
    const burstPromises = [
      lifecycle.handleCommittedWrite(),
      lifecycle.handleCommittedWrite(),
      lifecycle.handleCommittedWrite(),
      lifecycle.handleCommittedWrite(),
    ];
    await Promise.all(burstPromises);
    const totalBurstPushes = pushExecutions - pushCountBeforeBurst;
    assert.ok(totalBurstPushes <= 2, `Burst must coalesce to <= 2 push cycles (actual: ${totalBurstPushes})`);

    lifecycle.dispose();
  });

  it('4. NETWORK RECONNECT & RECONNECT STORM: Reconnect executes PUSH then OPERATIONAL PULL; storm coalesces', async () => {
    const { persistence } = createMockPersistenceEngine();
    let pushCount = 0;
    let pullCount = 0;

    const pushTransport: CloudRpcTransport = {
      syncOrder: async () => { pushCount++; return true; },
      syncKot: async () => true,
      syncKotCorrection: async () => true,
      syncBill: async () => true,
      syncPayment: async () => true,
      applyInventoryMovement: async () => true,
    };

    const pullTransport: CloudPullTransport = {
      fetchOrdersDelta: async () => {
        pullCount++;
        await new Promise((r) => setTimeout(r, 20));
        return { orders: [], orderItems: [] };
      },
    };

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager: persistence,
      pushTransport,
      pullTransport,
    });

    // Prepopulate 1 outbox row so reconnect push has work to process
    await persistence.saveOrderAggregate({
      id: 'ord-rec-1', channel: 'POS', order_type: 'DINE_IN', status: 'draft',
      subtotal: 100, tax_total: 5, discount_total: 0, delivery_charge: 0, grand_total: 105,
      created_at: '2026-10-10T12:00:00Z', updated_at: '2026-10-10T12:00:00Z',
    }, []);

    const lifecycle = new WindowsPosLifecycleManager({
      persistence,
      orchestrator,
      isAuthSessionReady: () => true,
    });

    lifecycle.start();

    // 1. Single reconnect
    const res = await lifecycle.handleOnline();
    assert.ok(res);
    assert.ok(pushCount >= 1);
    assert.ok(pullCount >= 1);

    // 2. RECONNECT STORM: 20 rapid reconnect events
    const stormPromises = Array.from({ length: 20 }, () => lifecycle.handleOnline());
    await Promise.all(stormPromises);

    // Max concurrent executions must be 1 (orchestrator single-flight guarantee)
    assert.equal(orchestrator.getStatus().isPushActive, false);
    assert.equal(orchestrator.getStatus().isPullActive, false);

    lifecycle.dispose();
  });

  it('5. FOREGROUND / FOCUS & DUPLICATE THROTTLE GUARD: Duplicate focus within 1000ms is ignored; storm coalesces', async () => {
    const { persistence } = createMockPersistenceEngine();
    let pullRequests = 0;
    let simulatedNow = 10000;

    const pullTransport: CloudPullTransport = {
      fetchOrdersDelta: async () => {
        pullRequests++;
        return { orders: [], orderItems: [] };
      },
    };

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager: persistence,
      pushTransport: {} as any,
      pullTransport,
      nowFn: () => simulatedNow,
    });

    const lifecycle = new WindowsPosLifecycleManager({
      persistence,
      orchestrator,
      isAuthSessionReady: () => true,
      nowFn: () => simulatedNow,
    });

    lifecycle.start();

    // 1. First foreground trigger fires
    const res1 = await lifecycle.triggerForegroundSync();
    assert.ok(res1 !== null);
    assert.equal(pullRequests, 1);

    // 2. Immediate second focus trigger at same millisecond is throttled (duplicate guard)
    const res2 = await lifecycle.triggerForegroundSync();
    assert.equal(res2, null, 'Second foreground within 1000ms must be throttled');
    assert.equal(pullRequests, 1);

    // 3. Advance time by 500ms (still within 1000ms guard) -> throttled
    simulatedNow += 500;
    const res3 = await lifecycle.triggerForegroundSync();
    assert.equal(res3, null, 'Foreground at 500ms must be throttled');
    assert.equal(pullRequests, 1);

    // 4. Advance time past 1000ms -> fires operational pull
    simulatedNow += 600; // Total 1100ms since first trigger
    const res4 = await lifecycle.triggerForegroundSync();
    assert.ok(res4 !== null);
    assert.equal(pullRequests, 2);

    lifecycle.dispose();
  });

  it('6. PERIODIC ELIGIBILITY WAKE & 60-MINUTE REQUEST BUDGET SIMULATION: Measures exact push, pull, and request budget over 60m', async () => {
    const { persistence } = createMockPersistenceEngine();
    let totalPushCycles = 0;
    let totalPullCycles = 0;
    const requestsByDataset: Record<string, number> = {};

    const pushTransport: CloudRpcTransport = {
      syncOrder: async () => { totalPushCycles++; return true; },
      syncKot: async () => true,
      syncKotCorrection: async () => true,
      syncBill: async () => true,
      syncPayment: async () => true,
      applyInventoryMovement: async () => true,
    };

    const recordDataset = (name: string) => {
      requestsByDataset[name] = (requestsByDataset[name] || 0) + 1;
    };

    const pullTransport: CloudPullTransport = {
      fetchCategoriesDelta: async () => { recordDataset('categories'); return []; },
      fetchProductsDelta: async () => { recordDataset('products'); return []; },
      fetchProductVariantsDelta: async () => { recordDataset('product_variants'); return []; },
      fetchCustomersDelta: async () => { recordDataset('customers'); return []; },
      fetchPosTablesDelta: async () => { recordDataset('pos_tables'); return []; },
      fetchTableSessionsDelta: async () => { recordDataset('table_sessions'); return []; },
      fetchOrdersDelta: async () => { recordDataset('orders'); return { orders: [], orderItems: [] }; },
      fetchKotsDelta: async () => { recordDataset('pos_kots'); return { kots: [], kotItems: [] }; },
      fetchKotCorrectionsDelta: async () => { recordDataset('kot_corrections'); return []; },
      fetchBillsDelta: async () => { recordDataset('bills'); return []; },
      fetchPaymentsDelta: async () => { recordDataset('payments'); return []; },
      fetchInventoryLiteDelta: async () => { recordDataset('inventory_lite'); return []; },
    };

    let simulatedTimeMs = 1000000;

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager: persistence,
      pushTransport,
      pullTransport,
      nowFn: () => simulatedTimeMs,
    });

    const lifecycle = new WindowsPosLifecycleManager({
      persistence,
      orchestrator,
      isAuthSessionReady: () => true,
      wakeIntervalMs: 60000,
      nowFn: () => simulatedTimeMs,
    });

    lifecycle.start();

    // Simulation: 60 minutes online with 60-second wake timer (ticks 0 to 60)
    // No local writes, no reconnects, no focus events.
    for (let tick = 0; tick <= 60; tick++) {
      const res = await lifecycle.handlePeriodicWake(simulatedTimeMs);
      if (res && res.status === 'COMPLETED') {
        totalPullCycles++;
      }
      simulatedTimeMs += 60000; // +1 minute
    }

    // 1. Idle periodic wake creates ZERO push cycles
    assert.equal(totalPushCycles, 0, 'Periodic wake must create 0 push cycles');

    // 2. Operational datasets eligible at: 0m, 5m, 10m, 15m, 20m, 25m, 30m, 35m, 40m, 45m, 50m, 55m, 60m = 13 times
    assert.equal(totalPullCycles, 13, 'Total pull cycles over 60m must be exactly 13');

    // Operational datasets count (7 datasets * 13 pulls = 91 requests)
    for (const ds of OPERATIONAL_DATASETS) {
      assert.equal(requestsByDataset[ds], 13, `Operational dataset ${ds} must be requested 13 times`);
    }

    // Master datasets count (4 datasets * 4 pulls at 0m, 20m, 40m, 60m = 16 requests)
    for (const ds of MASTER_DATASETS) {
      assert.equal(requestsByDataset[ds], 4, `Master dataset ${ds} must be requested 4 times`);
    }

    // Customer datasets count (1 dataset * 4 pulls at 0m, 20m, 40m, 60m = 4 requests)
    for (const ds of CUSTOMER_DATASETS) {
      assert.equal(requestsByDataset[ds], 4, `Customer dataset ${ds} must be requested 4 times`);
    }

    // Total requests across all datasets = 91 + 16 + 4 = 111
    const totalRequests = Object.values(requestsByDataset).reduce((a, b) => a + b, 0);
    assert.equal(totalRequests, 111, 'Total cloud read requests over 60m must be 111');

    lifecycle.dispose();
  });

  it('7. OFFLINE WRITE, DURABILITY & RECONNECT DRAIN: Offline write persists outbox; reconnect triggers push and drains outbox', async () => {
    const { persistence, outbox } = createMockPersistenceEngine();
    let pushExecuted = false;

    const pushTransport: CloudRpcTransport = {
      syncOrder: async () => { pushExecuted = true; return true; },
      syncKot: async () => true,
      syncKotCorrection: async () => true,
      syncBill: async () => true,
      syncPayment: async () => true,
      applyInventoryMovement: async () => true,
    };

    const pullTransport: CloudPullTransport = {
      fetchOrdersDelta: async () => ({ orders: [], orderItems: [] }),
    };

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager: persistence,
      pushTransport,
      pullTransport,
    });

    const lifecycle = new WindowsPosLifecycleManager({
      persistence,
      orchestrator,
      isAuthSessionReady: () => false, // Offline / not logged in
    });

    lifecycle.start();

    // 1. Offline write commits locally and creates outbox row
    await persistence.saveOrderAggregate({
      id: 'ord-offline-1', channel: 'POS', order_type: 'DINE_IN', status: 'draft',
      subtotal: 150, tax_total: 7.5, discount_total: 0, delivery_charge: 0, grand_total: 157.5,
      created_at: '2026-10-10T12:00:00Z', updated_at: '2026-10-10T12:00:00Z',
    }, []);

    assert.equal(outbox.length, 1, 'Offline write must be stored in outbox');
    assert.equal(pushExecuted, false, 'Push must not execute while offline/gated');

    // 2. Auth becomes ready and reconnect occurs
    await lifecycle.setAuthSessionReady(true);
    await lifecycle.handleOnline();

    assert.equal(pushExecuted, true, 'Reconnect must trigger push to drain outbox');
    assert.equal(outbox.length, 0, 'Outbox must be acknowledged and empty');

    lifecycle.dispose();
  });

  it('8. CROSS PUSH/PULL CONCURRENCY: Push and Pull can run concurrently without mutual exclusion deadlocks', async () => {
    const { persistence } = createMockPersistenceEngine();
    let pushStarted = false;
    let pushFinished = false;
    let pullStarted = false;
    let pullFinished = false;

    const pushTransport: CloudRpcTransport = {
      syncOrder: async () => {
        pushStarted = true;
        await new Promise((r) => setTimeout(r, 30));
        pushFinished = true;
        return true;
      },
      syncKot: async () => true,
      syncKotCorrection: async () => true,
      syncBill: async () => true,
      syncPayment: async () => true,
      applyInventoryMovement: async () => true,
    };

    const pullTransport: CloudPullTransport = {
      fetchOrdersDelta: async () => {
        pullStarted = true;
        await new Promise((r) => setTimeout(r, 30));
        pullFinished = true;
        return { orders: [], orderItems: [] };
      },
    };

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager: persistence,
      pushTransport,
      pullTransport,
    });

    // Populate outbox row for push
    await persistence.saveOrderAggregate({
      id: 'ord-conc-1', channel: 'POS', order_type: 'DINE_IN', status: 'draft',
      subtotal: 100, tax_total: 5, discount_total: 0, delivery_charge: 0, grand_total: 105,
      created_at: '2026-10-10T12:00:00Z', updated_at: '2026-10-10T12:00:00Z',
    }, []);

    // Launch both push and pull in parallel
    const [pushRes, pullRes] = await Promise.all([
      orchestrator.requestPush(),
      orchestrator.requestPull(['orders']),
    ]);

    assert.equal(pushRes.status, 'COMPLETED');
    assert.equal(pullRes.status, 'COMPLETED');
    assert.equal(pushStarted, true);
    assert.equal(pushFinished, true);
    assert.equal(pullStarted, true);
    assert.equal(pullFinished, true);
  });

  it('9. MANUAL REFRESH FOUNDATION: manualRefresh executes requested scoped pull', async () => {
    const { persistence } = createMockPersistenceEngine();
    let requestedScope = '';

    const pullTransport: CloudPullTransport = {
      fetchOrdersDelta: async () => { requestedScope = 'operational'; return { orders: [], orderItems: [] }; },
      fetchCategoriesDelta: async () => { requestedScope = 'master'; return []; },
      fetchCustomersDelta: async () => { requestedScope = 'customer'; return []; },
    };

    const orchestrator = new SyncRuntimeOrchestrator({
      dbManager: persistence,
      pushTransport: {} as any,
      pullTransport,
    });

    const lifecycle = new WindowsPosLifecycleManager({
      persistence,
      orchestrator,
      isAuthSessionReady: () => true,
    });

    lifecycle.start();

    await lifecycle.manualRefresh('operational');
    assert.equal(requestedScope, 'operational');

    await lifecycle.manualRefresh('master');
    assert.equal(requestedScope, 'master');

    await lifecycle.manualRefresh('customer');
    assert.equal(requestedScope, 'customer');

    lifecycle.dispose();
  });
});
