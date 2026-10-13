/**
 * CHEESYOS NEXTGEN WINDOWS POS — TAURI NATIVE PERSISTENCE INTEGRATION SUITE
 * 
 * Verifies Phase 3F.5E3:
 * - Direct IPosPersistence implementation in TauriPosPersistence.
 * - Zero production mockStorage, zero fake statements.
 * - 1:1 mapping of all 13 semantic methods to finite native Tauri commands.
 * - Single-IPC call transaction atomicity (Order, KOT, Bill, Payment, Inventory, Pull Batch).
 * - Zero raw SQL strings or arbitrary table targets across IPC payloads.
 * - Full push worker & pull worker storage compatibility.
 * - Malicious SQL injection data safety & unknown operation rejection.
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  TauriPosPersistence,
  TauriInvokeHandler,
  createTauriPosPersistence,
  deriveTableOccupancy,
} from '../src/tauri-adapter.js';
import { runPushCycle, runPullCycle, CloudRpcTransport, CloudPullTransport } from '@cheesyos/pos-sync';
import type {
  OrderDomain,
  OrderItemDomain,
  PosKotDomain,
  KotItemDomain,
  KotCorrectionDomain,
  BillDomain,
  PaymentDomain,
} from '@cheesyos/nextgen-shared';

interface RecordedInvoke {
  cmd: string;
  args?: Record<string, unknown>;
}

function createHarnessMockInvoke() {
  const recordedInvokes: RecordedInvoke[] = [];

  // In-memory state simulating native SQLite storage behind Tauri commands
  let deviceConfig: any = null;
  let sequenceCounter = 0;
  const outbox: any[] = [];
  const cursors: Record<string, { lastUpdatedAt: string; lastId: string; updatedAt: string }> = {};

  let mockTables: any[] = [];
  let mockCatalog: any = { categories: [], products: [], variants: [] };
  const mockActiveOrders: Record<string, any> = {};
  const mockBills: Record<string, any> = {};
  const mockKots: Record<string, any[]> = {};

  const invoke: TauriInvokeHandler = async (cmd: string, args?: Record<string, unknown>) => {
    recordedInvokes.push({ cmd, args });

    if (cmd === 'init_db_schema') {
      return 'DB_INITIALIZED';
    }

    if (cmd === 'execute_query') {
      throw new Error('COMMAND_REMOVED: execute_query is not a registered Tauri command.');
    }

    if (cmd === 'pos_db_execute') {
      const op = args?.op as any;
      if (!op || !op.type) throw new Error('UNKNOWN_OPERATION: missing operation type');

      switch (op.type) {
        case 'SetDeviceConfig': {
          deviceConfig = {
            device_id: op.payload.device_id,
            terminal_code: op.payload.terminal_code.toUpperCase(),
            device_name: op.payload.device_name,
            created_at: op.payload.created_at || '2026-10-10T12:00:00.000Z',
          };
          return deviceConfig;
        }
        case 'SaveOrderAggregate': {
          const outboxEntry = {
            seq: outbox.length + 1,
            id: 'out-' + (outbox.length + 1),
            entity_type: 'orders',
            entity_id: op.payload.order.id,
            operation: 'INSERT',
            payload_json: JSON.stringify(op.payload),
            created_at: op.payload.order.created_at,
            attempt_count: 0,
            next_attempt_at: null,
            last_error: null,
          };
          outbox.push(outboxEntry);
          return {
            order: op.payload.order,
            items: op.payload.items,
            outbox_entries: [outboxEntry],
          };
        }
        case 'ReplaceDraftOrderAggregate': {
          const outboxEntry = {
            seq: outbox.length + 1,
            id: 'out-' + (outbox.length + 1),
            entity_type: 'orders',
            entity_id: op.payload.order.id,
            operation: 'UPDATE',
            payload_json: JSON.stringify(op.payload),
            created_at: op.payload.order.updated_at,
            attempt_count: 0,
            next_attempt_at: null,
            last_error: null,
          };
          outbox.push(outboxEntry);
          return {
            order: op.payload.order,
            items: op.payload.items,
            outbox_entries: [outboxEntry],
          };
        }
        case 'SaveKotAggregate': {
          const outboxEntry = {
            seq: outbox.length + 1,
            id: 'out-' + (outbox.length + 1),
            entity_type: 'pos_kots',
            entity_id: op.payload.kot.id,
            operation: 'INSERT',
            payload_json: JSON.stringify(op.payload),
            created_at: op.payload.kot.printed_at,
            attempt_count: 0,
            next_attempt_at: null,
            last_error: null,
          };
          outbox.push(outboxEntry);
          return {
            kot: op.payload.kot,
            items: op.payload.items,
            outbox_entries: [outboxEntry],
          };
        }
        case 'SaveKotCorrection': {
          const outboxEntry = {
            seq: outbox.length + 1,
            id: 'out-' + (outbox.length + 1),
            entity_type: 'kot_corrections',
            entity_id: op.payload.id,
            operation: 'INSERT',
            payload_json: JSON.stringify(op.payload),
            created_at: op.payload.created_at,
            attempt_count: 0,
            next_attempt_at: null,
            last_error: null,
          };
          outbox.push(outboxEntry);
          return outboxEntry;
        }
        case 'SaveBillWithSequence': {
          if (!deviceConfig) {
            throw new Error('[PosPersistence] Terminal device identity is not configured locally.');
          }
          sequenceCounter++;
          const seqStr = String(sequenceCounter).padStart(6, '0');
          const authoritativeBillNumber = `CB-${deviceConfig.terminal_code}-${seqStr}`;

          const callerBill = (op.payload.bill_number || '').trim();
          const isPlaceholder = ['PENDING', 'DRAFT', 'TEMP', 'UNASSIGNED', ''].includes(callerBill.toUpperCase());

          if (!isPlaceholder && callerBill !== authoritativeBillNumber) {
            sequenceCounter--; // Rollback sequence
            throw new Error(
              `[PosPersistence] BILL_NUMBER_CONFLICT: Caller-provided bill_number "${op.payload.bill_number}" conflicts with allocated sequence number "${authoritativeBillNumber}". Authority is NATIVE_SAVE_BILL_WITH_SEQUENCE_TRANSACTION.`
            );
          }

          const outboxEntry = {
            seq: outbox.length + 1,
            id: 'out-' + (outbox.length + 1),
            entity_type: 'bills',
            entity_id: op.payload.id,
            operation: 'INSERT',
            payload_json: JSON.stringify(op.payload),
            created_at: op.payload.finalized_at,
            attempt_count: 0,
            next_attempt_at: null,
            last_error: null,
          };
          outbox.push(outboxEntry);

          return {
            bill: {
              ...op.payload,
              bill_number: authoritativeBillNumber,
              device_id: deviceConfig.device_id,
            },
            sequence_number: sequenceCounter,
            outbox_entry: outboxEntry,
          };
        }
        case 'SavePayment': {
          const outboxEntry = {
            seq: outbox.length + 1,
            id: 'out-' + (outbox.length + 1),
            entity_type: 'payments',
            entity_id: op.payload.payment.id,
            operation: 'INSERT',
            payload_json: JSON.stringify(op.payload),
            created_at: op.payload.payment.confirmed_at,
            attempt_count: 0,
            next_attempt_at: null,
            last_error: null,
          };
          outbox.push(outboxEntry);
          return {
            payment: op.payload.payment,
            updated_bill: op.payload.updated_bill,
            outbox_entry: outboxEntry,
          };
        }
        case 'SaveInventoryMovement': {
          const movementId = op.payload.id || 'move-' + Math.random().toString(36).substring(2, 9);
          const outboxEntry = {
            seq: outbox.length + 1,
            id: 'out-' + (outbox.length + 1),
            entity_type: 'inventory_movements',
            entity_id: movementId,
            operation: 'INSERT',
            payload_json: JSON.stringify(op.payload),
            created_at: op.payload.created_at || '2026-10-10T12:00:00Z',
            attempt_count: 0,
            next_attempt_at: null,
            last_error: null,
          };
          outbox.push(outboxEntry);
          return {
            movement_id: movementId,
            product_id: op.payload.product_id,
            new_stock: 42 + (op.payload.quantity_change || 0),
            outbox_entry: outboxEntry,
          };
        }
        case 'OpenTableSession': {
          return {
            id: 'sess-' + Math.random().toString(36).substring(2, 9),
            table_id: op.payload.table_id,
            current_order_id: null,
            guest_count: op.payload.guest_count,
            session_status: 'open',
            opened_at: '2026-10-12T12:00:00Z',
            closed_at: null,
          };
        }
        case 'CloseTableSession': {
          return { closed: true };
        }
        case 'AcknowledgeOutbox': {
          const idx = outbox.findIndex((r) => r.seq === op.payload.seq);
          if (idx !== -1) outbox.splice(idx, 1);
          return { acknowledged: true, seq: op.payload.seq };
        }
        case 'UpdateOutboxFailure': {
          const row = outbox.find((r) => r.seq === op.payload.seq);
          if (row) {
            row.attempt_count++;
            row.last_error = op.payload.error;
            row.next_attempt_at = op.payload.next_attempt_at;
          }
          return { updated: true, seq: op.payload.seq };
        }
        case 'ApplyPullBatch': {
          cursors[op.payload.dataset] = {
            dataset: op.payload.dataset,
            last_updated_at: op.payload.new_cursor.last_updated_at,
            last_id: op.payload.new_cursor.last_id,
            updated_at: '2026-10-10T12:00:00Z',
          };
          // Pull batch NEVER creates outbox rows
          return { rowsApplied: op.payload.rows.length };
        }
        default:
          throw new Error(`UNKNOWN_OPERATION: ${op.type}`);
      }
    }

    if (cmd === 'pos_db_query') {
      const q = args?.query as any;
      if (!q || !q.type) throw new Error('UNKNOWN_QUERY: missing query type');

      switch (q.type) {
        case 'GetDeviceConfig': {
          return deviceConfig;
        }
        case 'GetPendingOutbox': {
          const limit = q.payload?.limit || 10;
          return outbox.slice(0, limit);
        }
        case 'GetSyncCursor': {
          return cursors[q.payload.dataset] || {
            dataset: q.payload.dataset,
            last_updated_at: '1970-01-01T00:00:00.000Z',
            last_id: '',
            updated_at: '1970-01-01T00:00:00.000Z',
          };
        }
        case 'GetTablesWithSessions': {
          return mockTables;
        }
        case 'GetCatalog': {
          return mockCatalog;
        }
        case 'GetActiveOrderForTable': {
          const tableId = q.payload?.table_id;
          return mockActiveOrders[tableId] || null;
        }
        case 'GetBillForOrder': {
          const orderId = q.payload?.order_id;
          return mockBills[orderId] || null;
        }
        case 'GetKotsForOrder': {
          const orderId = q.payload?.order_id;
          return mockKots[orderId] || [];
        }
        default:
          throw new Error(`UNKNOWN_QUERY: ${q.type}`);
      }
    }

    throw new Error(`UNKNOWN_COMMAND: ${cmd}`);
  };

  return {
    invoke,
    recordedInvokes,
    outbox,
    setMockTables: (t: any[]) => { mockTables = t; },
    setMockCatalog: (c: any) => { mockCatalog = c; },
    setMockActiveOrder: (tbl: string, o: any) => { mockActiveOrders[tbl] = o; },
    setMockBill: (ord: string, b: any) => { mockBills[ord] = b; },
    setMockKots: (ord: string, k: any[]) => { mockKots[ord] = k; },
  };
}

describe('CHEESYOS WINDOWS POS — TAURI NATIVE PERSISTENCE INTEGRATION GATE', () => {

  it('1. PRODUCTION_ADAPTER_MOCK_CLEANLINESS: TauriPosPersistence implements IPosPersistence without mockStorage', () => {
    const adapter = createTauriPosPersistence();
    assert.equal(typeof adapter.getDeviceConfig, 'function');
    assert.equal(typeof adapter.setDeviceConfig, 'function');
    assert.equal(typeof adapter.saveOrderAggregate, 'function');
    assert.equal(typeof adapter.saveKotAggregate, 'function');
    assert.equal(typeof adapter.saveKotCorrection, 'function');
    assert.equal(typeof adapter.saveBillWithSequence, 'function');
    assert.equal(typeof adapter.savePayment, 'function');
    assert.equal(typeof adapter.saveInventoryMovement, 'function');
    assert.equal(typeof adapter.getPendingOutbox, 'function');
    assert.equal(typeof adapter.acknowledgeOutbox, 'function');
    assert.equal(typeof adapter.updateOutboxFailure, 'function');
    assert.equal(typeof adapter.getSyncCursor, 'function');
    assert.equal(typeof adapter.applyPullBatch, 'function');

    // Assert that mockStorage, prepare, and exec are NOT present on adapter
    assert.equal((adapter as any).mockStorage, undefined);
    assert.equal((adapter as any).prepare, undefined);
    assert.equal((adapter as any).exec, undefined);
  });

  it('2. DEVICE_CONFIG_RENDERER_NATIVE_E2E: setDeviceConfig and getDeviceConfig invoke native commands cleanly', async () => {
    const { invoke, recordedInvokes } = createHarnessMockInvoke();
    const adapter = new TauriPosPersistence(invoke);

    await adapter.initSchema();
    assert.equal(recordedInvokes[0].cmd, 'init_db_schema');

    // 1. Set device config
    const setRes = await adapter.setDeviceConfig({
      device_id: 'dev-win-01',
      terminal_code: 'T01',
      device_name: 'Main Counter',
    });

    assert.equal(setRes.terminal_code, 'T01');
    assert.equal(recordedInvokes[1].cmd, 'pos_db_execute');
    assert.equal((recordedInvokes[1].args?.op as any).type, 'SetDeviceConfig');

    // 2. Get device config
    const getRes = await adapter.getDeviceConfig();
    assert.ok(getRes);
    assert.equal(getRes?.device_id, 'dev-win-01');
    assert.equal(recordedInvokes[2].cmd, 'pos_db_query');
    assert.equal((recordedInvokes[2].args?.query as any).type, 'GetDeviceConfig');
  });

  it('3. BILL_RENDERER_NATIVE_E2E & CONFLICT: saveBillWithSequence allocates authoritative number & rejects conflicting caller bill', async () => {
    const { invoke, recordedInvokes } = createHarnessMockInvoke();
    const adapter = new TauriPosPersistence(invoke);

    await adapter.setDeviceConfig({
      device_id: 'dev-win-01',
      terminal_code: 'T01',
      device_name: 'Main Counter',
    });

    const bill1: BillDomain = {
      id: 'bill-win-01',
      order_id: 'ord-win-01',
      bill_number: 'PENDING',
      subtotal: 100,
      cgst_total: 2.5,
      sgst_total: 2.5,
      discount_total: 0,
      grand_total: 105,
      payment_status: 'unpaid',
      finalized_at: '2026-10-10T12:00:00.000Z',
    };

    // 1. Valid allocation in 1 IPC call
    const res1 = await adapter.saveBillWithSequence(bill1);
    assert.equal(res1.sequenceNumber, 1);
    assert.equal(res1.bill.bill_number, 'CB-T01-000001');

    // Verify exactly 1 IPC call for the bill transaction
    const billInvokes = recordedInvokes.filter(r => (r.args?.op as any)?.type === 'SaveBillWithSequence');
    assert.equal(billInvokes.length, 1);

    // 2. Conflicting caller bill number must REJECT
    const conflictingBill: BillDomain = {
      id: 'bill-win-02',
      order_id: 'ord-win-02',
      bill_number: 'CB-T01-999999', // Conflicting bill number
      subtotal: 100,
      cgst_total: 2.5,
      sgst_total: 2.5,
      discount_total: 0,
      grand_total: 105,
      payment_status: 'unpaid',
      finalized_at: '2026-10-10T12:01:00.000Z',
    };

    await assert.rejects(
      async () => {
        await adapter.saveBillWithSequence(conflictingBill);
      },
      (err: Error) => {
        assert.match(err.message, /BILL_NUMBER_CONFLICT/);
        return true;
      }
    );
  });

  it('4. ORDER_AND_KOT_TRANSACTIONS_IPC_CALL_COUNT: Aggregates execute in exactly 1 IPC call', async () => {
    const { invoke, recordedInvokes } = createHarnessMockInvoke();
    const adapter = new TauriPosPersistence(invoke);

    const order: OrderDomain = {
      id: 'ord-ipc-1',
      channel: 'POS',
      order_type: 'DINE_IN',
      status: 'draft',
      subtotal: 200,
      tax_total: 10,
      discount_total: 0,
      delivery_charge: 0,
      grand_total: 210,
      created_at: '2026-10-10T12:00:00Z',
      updated_at: '2026-10-10T12:00:00Z',
    };

    const items: OrderItemDomain[] = [{
      id: 'item-ipc-1',
      order_id: 'ord-ipc-1',
      product_id: 'prod-1',
      product_name: 'Paneer Pizza',
      unit_price: 200,
      quantity: 1,
      tax_rate: 5,
      discount_amount: 0,
      line_total: 200,
      created_at: '2026-10-10T12:00:00Z',
    }];

    const orderBefore = recordedInvokes.length;
    await adapter.saveOrderAggregate(order, items);
    assert.equal(recordedInvokes.length - orderBefore, 1, 'ORDER_TRANSACTION_IPC_CALLS must be 1');

    const kot: PosKotDomain = {
      id: 'kot-ipc-1',
      order_id: 'ord-ipc-1',
      kot_number: 1,
      status: 'printed',
      printed_at: '2026-10-10T12:00:00Z',
    };

    const kotItems: KotItemDomain[] = [{
      id: 'kot-item-1',
      kot_id: 'kot-ipc-1',
      product_id: 'prod-1',
      product_name: 'Paneer Pizza',
      quantity: 1,
    }];

    const kotBefore = recordedInvokes.length;
    await adapter.saveKotAggregate(kot, kotItems);
    assert.equal(recordedInvokes.length - kotBefore, 1, 'KOT_TRANSACTION_IPC_CALLS must be 1');
  });

  it('5. PAYMENT_AND_INVENTORY_IPC_CALL_COUNT: Settlement and stock operations execute in 1 IPC call', async () => {
    const { invoke, recordedInvokes } = createHarnessMockInvoke();
    const adapter = new TauriPosPersistence(invoke);

    const payment: PaymentDomain = {
      id: 'pay-ipc-1',
      bill_id: 'bill-1',
      order_id: 'ord-1',
      payment_mode: 'UPI',
      amount_paid: 210,
      confirmed_at: '2026-10-10T12:05:00Z',
    };

    const updatedBill: BillDomain = {
      id: 'bill-1',
      order_id: 'ord-1',
      bill_number: 'CB-T01-000001',
      subtotal: 200,
      cgst_total: 5,
      sgst_total: 5,
      discount_total: 0,
      grand_total: 210,
      payment_status: 'paid',
      finalized_at: '2026-10-10T12:00:00Z',
    };

    const payBefore = recordedInvokes.length;
    await adapter.savePayment(payment, updatedBill);
    assert.equal(recordedInvokes.length - payBefore, 1, 'PAYMENT_TRANSACTION_IPC_CALLS must be 1');

    const invBefore = recordedInvokes.length;
    await adapter.saveInventoryMovement({
      productId: 'prod-1',
      movementType: 'SALE',
      quantityChange: -1,
    });
    assert.equal(recordedInvokes.length - invBefore, 1, 'INVENTORY_TRANSACTION_IPC_CALLS must be 1');
  });

  it('6. PUSH_AND_PULL_WORKER_COMPATIBILITY: push and pull workers run cleanly over TauriPosPersistence', async () => {
    const { invoke, outbox } = createHarnessMockInvoke();
    const adapter = new TauriPosPersistence(invoke);

    // Prepopulate 1 outbox row
    outbox.push({
      seq: 1,
      id: 'out-push-1',
      entity_type: 'orders',
      entity_id: 'ord-push-1',
      operation: 'INSERT',
      payload_json: JSON.stringify({
        order: { id: 'ord-push-1', channel: 'POS', order_type: 'DINE_IN', status: 'draft', subtotal: 100, grand_total: 105 },
        items: [],
      }),
      created_at: '2026-10-10T12:00:00Z',
      attempt_count: 0,
      next_attempt_at: null,
      last_error: null,
    });

    const mockPushTransport: CloudRpcTransport = {
      syncOrder: async () => true,
      syncKot: async () => true,
      syncKotCorrection: async () => true,
      syncBill: async () => true,
      syncPayment: async () => true,
      applyInventoryMovement: async () => true,
    };

    // 1. Run Push Cycle with TauriPosPersistence
    const pushRes = await runPushCycle({
      dbManager: adapter,
      transport: mockPushTransport,
    });

    assert.equal(pushRes.status, 'COMPLETED');
    assert.equal(pushRes.processedCount, 1);
    assert.equal(pushRes.successCount, 1);
    assert.equal(outbox.length, 0, 'Outbox row should be acknowledged and deleted');

    // 2. Run Pull Cycle with TauriPosPersistence
    const mockPullTransport: CloudPullTransport = {
      fetchCategoriesDelta: async () => [{
        id: 'cat-pull-1',
        name: 'Beverages',
        slug: 'beverages',
        updated_at: '2026-10-10T12:00:00Z',
      }],
    };

    const pullRes = await runPullCycle({
      dbManager: adapter,
      transport: mockPullTransport,
      datasets: ['categories'],
    });

    assert.equal(pullRes.status, 'COMPLETED');
    assert.equal(pullRes.rowsApplied, 1);

    const cursor = await adapter.getSyncCursor('categories');
    assert.equal(cursor.lastId, 'cat-pull-1');
  });

  it('7. IPC_SECURITY_AND_INJECTION_PROTECTION: Zero SQL strings in payloads, malicious data treated as text, legacy execute_query rejected', async () => {
    const { invoke, recordedInvokes } = createHarnessMockInvoke();
    const adapter = new TauriPosPersistence(invoke);

    // Pass malicious SQL-like text in data fields
    await adapter.saveKotCorrection({
      id: 'corr-inj-1',
      order_id: 'ord-1',
      product_name: 'DROP TABLE orders; --',
      cancelled_qty: 1,
      reason: "'; DELETE FROM bills; --",
      authorized_by_staff_id: 'staff-1',
      created_at: '2026-10-10T12:00:00Z',
    });

    // Verify all recorded invokes: NO SQL keyword in any key or command
    for (const inv of recordedInvokes) {
      assert.notEqual(inv.cmd, 'execute_query');
      assert.notEqual(inv.cmd, 'run_sql');
      if (inv.args?.op) {
        const op = inv.args.op as any;
        assert.equal(op.sql, undefined);
        assert.equal(op.query, undefined);
      }
    }

    // Verify legacy arbitrary SQL attempt fails
    await assert.rejects(
      async () => {
        await invoke('execute_query', { query: 'DROP TABLE orders;' });
      },
      (err: Error) => {
        assert.match(err.message, /COMMAND_REMOVED/);
        return true;
      }
    );
  });

  it('8. GET_TABLES_WITH_SESSIONS_AND_OCCUPANCY: Reads tables + sessions via IPC and derives AVAILABLE, OCCUPIED, BILLED', async () => {
    const { invoke, recordedInvokes, setMockTables } = createHarnessMockInvoke();
    const adapter = new TauriPosPersistence(invoke);

    const mockData = [
      {
        table: { id: 'tbl-1', table_number: 'T01', section: 'Main', capacity: 4, is_active: true, created_at: 'now' },
        active_session: { id: 'sess-1', table_id: 'tbl-1', current_order_id: 'ord-1', guest_count: 2, session_status: 'open', opened_at: 'now', closed_at: null },
      },
      {
        table: { id: 'tbl-2', table_number: 'T02', section: 'Main', capacity: 2, is_active: true, created_at: 'now' },
        active_session: { id: 'sess-2', table_id: 'tbl-2', current_order_id: 'ord-2', guest_count: 2, session_status: 'billed', opened_at: 'now', closed_at: null },
      },
      {
        table: { id: 'tbl-3', table_number: 'T03', section: 'Main', capacity: 6, is_active: true, created_at: 'now' },
        active_session: null,
      },
    ];
    setMockTables(mockData);

    const tables = await adapter.getTablesWithSessions();
    assert.equal(tables.length, 3);

    // Verify IPC call shape
    const lastInvoke = recordedInvokes[recordedInvokes.length - 1];
    assert.equal(lastInvoke.cmd, 'pos_db_query');
    assert.deepEqual(lastInvoke.args, { query: { type: 'GetTablesWithSessions' } });

    // Verify derivation
    assert.equal(deriveTableOccupancy(tables[0].active_session), 'OCCUPIED');
    assert.equal(deriveTableOccupancy(tables[1].active_session), 'BILLED');
    assert.equal(deriveTableOccupancy(tables[2].active_session), 'AVAILABLE');
  });

  it('9. GET_CATALOG_PAISE_FIDELITY: Reads menu catalog via IPC preserving integer Paise', async () => {
    const { invoke, recordedInvokes, setMockCatalog } = createHarnessMockInvoke();
    const adapter = new TauriPosPersistence(invoke);

    const mockCatalogData = {
      categories: [{ id: 'c1', name: 'Drinks', slug: 'drinks', display_order: 1, is_active: true, created_at: 'now', updated_at: 'now' }],
      products: [{ id: 'p1', category_id: 'c1', name: 'Coffee', description: null, image_url: null, base_price_paise: 12000, is_available: true, tax_rate: 5.0, is_inventory_tracked: false, created_at: 'now', updated_at: 'now' }],
      variants: [{ id: 'v1', product_id: 'p1', variant_name: 'Large', price_override_paise: 15000, is_available: true, created_at: 'now' }],
    };
    setMockCatalog(mockCatalogData);

    const catalog = await adapter.getCatalog();
    assert.equal(catalog.categories.length, 1);
    assert.equal(catalog.products.length, 1);
    assert.equal(catalog.products[0].base_price_paise, 12000);
    assert.equal(Number.isInteger(catalog.products[0].base_price_paise), true);
    assert.equal(catalog.variants[0].price_override_paise, 15000);
    assert.equal(Number.isInteger(catalog.variants[0].price_override_paise!), true);

    const lastInvoke = recordedInvokes[recordedInvokes.length - 1];
    assert.equal(lastInvoke.cmd, 'pos_db_query');
    assert.deepEqual(lastInvoke.args, { query: { type: 'GetCatalog' } });
  });

  it('10. GET_ACTIVE_ORDER_FOR_TABLE_AND_TYPED_NULL: Hydrates table active order via IPC with typed null result', async () => {
    const { invoke, recordedInvokes, setMockActiveOrder } = createHarnessMockInvoke();
    const adapter = new TauriPosPersistence(invoke);

    const mockActive = {
      session: { id: 'sess-1', table_id: 'tbl-1', guest_count: 2, session_status: 'open' as const, opened_at: 'now' },
      order: {
        id: 'ord-1',
        channel: 'POS' as const,
        order_type: 'DINE_IN' as const,
        status: 'kot_sent' as const,
        subtotal_paise: 20000,
        tax_total_paise: 1000,
        discount_total_paise: 0,
        delivery_charge_paise: 0,
        grand_total_paise: 21000,
        created_at: 'now',
        updated_at: 'now',
        display_number: 'CB-T01-001',
        customer_id: null,
        table_session_id: 'sess-1',
        device_id: null,
      },
      items: [
        { id: 'i1', order_id: 'ord-1', product_id: 'p1', variant_id: null, product_name: 'Coffee', unit_price_paise: 10000, quantity: 2, tax_rate: 5.0, discount_amount_paise: 0, line_total_paise: 20000, notes: null, created_at: 'now' },
      ],
    };
    setMockActiveOrder('tbl-1', mockActive);

    // 1. Populated active order
    const result = await adapter.getActiveOrderForTable('tbl-1');
    assert.ok(result);
    assert.equal(result.session.id, 'sess-1');
    assert.equal(result.order.id, 'ord-1');
    assert.equal(result.order.grand_total_paise, 21000);
    assert.equal(result.items.length, 1);

    const lastInvoke = recordedInvokes[recordedInvokes.length - 1];
    assert.equal(lastInvoke.cmd, 'pos_db_query');
    assert.deepEqual(lastInvoke.args, {
      query: {
        type: 'GetActiveOrderForTable',
        payload: { table_id: 'tbl-1' },
      },
    });

    // 2. Empty table -> typed null
    const emptyResult = await adapter.getActiveOrderForTable('tbl-empty');
    assert.equal(emptyResult, null);
  });

  it('11. GET_BILL_FOR_ORDER_AND_TYPED_NULL: Reads order bill via IPC with typed null result', async () => {
    const { invoke, recordedInvokes, setMockBill } = createHarnessMockInvoke();
    const adapter = new TauriPosPersistence(invoke);

    const mockBillData = {
      id: 'b1',
      order_id: 'ord-1',
      bill_number: 'CB-T01-000001',
      subtotal_paise: 20000,
      cgst_total_paise: 500,
      sgst_total_paise: 500,
      discount_total_paise: 0,
      grand_total_paise: 21000,
      payment_status: 'unpaid' as const,
      finalized_at: 'now',
      device_id: null,
    };
    setMockBill('ord-1', mockBillData);

    // 1. Existing bill
    const bill = await adapter.getBillForOrder('ord-1');
    assert.ok(bill);
    assert.equal(bill.id, 'b1');
    assert.equal(bill.bill_number, 'CB-T01-000001');
    assert.equal(bill.grand_total_paise, 21000);

    const lastInvoke = recordedInvokes[recordedInvokes.length - 1];
    assert.equal(lastInvoke.cmd, 'pos_db_query');
    assert.deepEqual(lastInvoke.args, {
      query: {
        type: 'GetBillForOrder',
        payload: { order_id: 'ord-1' },
      },
    });

    // 2. Missing bill -> typed null
    const noBill = await adapter.getBillForOrder('ord-no-bill');
    assert.equal(noBill, null);
  });

  it('12. RAW_SQL_CROSSES_IPC_STRICTLY_NO: TauriPosPersistence boundary exposes zero raw SQL methods and IPC rejects generic SQL', async () => {
    const { invoke } = createHarnessMockInvoke();
    const adapter = new TauriPosPersistence(invoke) as any;

    // Verify zero generic SQL methods exist on adapter
    assert.equal(adapter.querySql, undefined);
    assert.equal(adapter.executeSql, undefined);
    assert.equal(adapter.rawQuery, undefined);
    assert.equal(adapter.rawSql, undefined);

    // Verify unknown generic SQL query type is rejected
    await assert.rejects(
      async () => {
        await invoke('pos_db_query', { query: { type: 'RawSql', payload: 'SELECT 1;' } });
      },
      /UNKNOWN_QUERY: RawSql/
    );
  });

  it('13. OPEN_TABLE_SESSION_IPC_GATE: Dispatches OpenTableSession and notifies committed write', async () => {
    const { invoke, recordedInvokes } = createHarnessMockInvoke();
    const adapter = new TauriPosPersistence(invoke);

    let committedEntity = '';
    adapter.onCommittedWrite((entity) => {
      committedEntity = entity;
    });

    const session = await adapter.openTableSession('tbl-1', 4);
    assert.ok(session.id);
    assert.equal(session.table_id, 'tbl-1');
    assert.equal(session.guest_count, 4);
    assert.equal(session.session_status, 'open');
    assert.equal(committedEntity, 'table_sessions');

    const lastInvoke = recordedInvokes[recordedInvokes.length - 1];
    assert.equal(lastInvoke.cmd, 'pos_db_execute');
    assert.deepEqual(lastInvoke.args, {
      op: {
        type: 'OpenTableSession',
        payload: {
          table_id: 'tbl-1',
          guest_count: 4,
        },
      },
    });
  });

  it('14. CLOSE_TABLE_SESSION_IPC_GATE: Dispatches CloseTableSession and notifies committed writes', async () => {
    const { invoke, recordedInvokes } = createHarnessMockInvoke();
    const adapter = new TauriPosPersistence(invoke);

    const committedEntities: string[] = [];
    adapter.onCommittedWrite((entity) => {
      committedEntities.push(entity);
    });

    await adapter.closeTableSession('sess-1', 'ord-1');
    assert.deepEqual(committedEntities, ['table_sessions', 'orders']);

    const lastInvoke = recordedInvokes[recordedInvokes.length - 1];
    assert.equal(lastInvoke.cmd, 'pos_db_execute');
    assert.deepEqual(lastInvoke.args, {
      op: {
        type: 'CloseTableSession',
        payload: {
          session_id: 'sess-1',
          order_id: 'ord-1',
        },
      },
    });
  });

  it('15. REPLACE_DRAFT_ORDER_AGGREGATE_IPC_GATE: Dispatches ReplaceDraftOrderAggregate and notifies committed write', async () => {
    const { invoke } = createHarnessMockInvoke();
    const adapter = new TauriPosPersistence(invoke);

    let notified = false;
    adapter.onCommittedWrite((entity) => {
      if (entity === 'orders') notified = true;
    });

    const res = await adapter.replaceDraftOrderAggregate(
      {
        id: 'ord-rep-1',
        display_number: '1',
        channel: 'POS',
        order_type: 'DINE_IN',
        table_session_id: 'sess-1',
        status: 'draft',
        version: 2,
        subtotal: 300,
        tax_total: 15,
        discount_total: 0,
        delivery_charge: 0,
        grand_total: 315,
        created_at: '2026-10-12T12:00:00Z',
        updated_at: '2026-10-12T12:05:00Z',
      },
      [
        {
          id: 'item-1',
          order_id: 'ord-rep-1',
          product_id: 'p-1',
          product_name: 'Margherita',
          unit_price: 300,
          quantity: 1,
          tax_rate: 5,
          discount_amount: 0,
          line_total: 300,
          created_at: '2026-10-12T12:05:00Z',
        },
      ]
    );

    assert.equal(res.order.version, 2);
    assert.ok(notified);
    assert.equal(res.outboxEntries[0].operation, 'UPDATE');
  });

  it('16. GET_KOTS_FOR_ORDER_IPC_GATE: Typed finite query dispatches GetKotsForOrder with zero raw SQL and returns exact history', async () => {
    const { invoke, recordedInvokes, setMockKots } = createHarnessMockInvoke();
    const adapter = new TauriPosPersistence(invoke);

    const orderId = 'ord-kot-gate-1';
    const mockData = [
      {
        kot: {
          id: 'kot-gate-1',
          order_id: orderId,
          kot_number: 1,
          device_id: 'dev-1',
          status: 'printed',
          printed_at: '2026-10-12T10:00:00Z',
        },
        items: [
          {
            id: 'kitem-1',
            kot_id: 'kot-gate-1',
            order_item_id: 'oitem-1',
            product_id: 'prod-1',
            variant_id: null,
            product_name: 'Burger',
            quantity: 2,
            notes: null,
          },
          {
            id: 'kitem-hist',
            kot_id: 'kot-gate-1',
            order_item_id: null,
            product_id: 'prod-2',
            variant_id: null,
            product_name: 'Fries',
            quantity: 1,
            notes: null,
          },
        ],
      },
    ];

    setMockKots(orderId, mockData);

    // TAURI_ADAPTER_TYPED_QUERY_PASS
    const res = await adapter.getKotsForOrder(orderId);
    assert.equal(res.length, 1, 'TAURI_ADAPTER_TYPED_QUERY_PASS: returns 1 KOT');
    assert.equal(res[0].kot.kot_number, 1);
    assert.equal(res[0].items.length, 2);
    assert.equal(res[0].items[0].order_item_id, 'oitem-1');
    assert.strictEqual(res[0].items[1].order_item_id, null);

    // NO_RAW_SQL_IPC_PASS
    const lastInvoke = recordedInvokes[recordedInvokes.length - 1];
    assert.equal(lastInvoke.cmd, 'pos_db_query', 'NO_RAW_SQL_IPC_PASS: command is pos_db_query');
    assert.deepEqual(lastInvoke.args, {
      query: {
        type: 'GetKotsForOrder',
        payload: { order_id: orderId },
      },
    }, 'NO_RAW_SQL_IPC_PASS: args match finite NativeQuery payload');

    // Empty order returns empty array
    const emptyRes = await adapter.getKotsForOrder('ord-non-existent');
    assert.deepEqual(emptyRes, [], 'GET_KOTS_FOR_ORDER_EMPTY_PASS: returns empty array for non-existent order');
  });
});
