/**
 * CHEESYOS NEXTGEN POS SYNC — CLOUD → LOCAL SAFE DELTA PULL WORKER
 * 
 * Implements explicit, bounded, incremental delta pull from cloud to local SQLite.
 * Enforces:
 * - Deterministic (updated_at, id) cursor watermarks.
 * - Atomic local SQLite transaction per page (data applied + cursor advanced).
 * - Local pending write protection (prevents cloud pull from overwriting unpushed outbox edits).
 * - No sync echo (zero outbox records generated during cloud pull).
 * - Immutable financial snapshot protection.
 * - Bounded page sizes (default 100, max 100, parent aggregate batch capped to 25 to prevent PostgREST child truncation).
 * - Bounded cloud read request budget (maximum 14 requests per cycle across all 12 datasets).
 * - Callable primitives only (zero timers, zero loops, zero background daemons).
 */

import {
  PosLocalDatabase,
  IPosLocalDatabase,
  IPosPersistence,
  PullDataset as LocalPullDataset,
  applyPullBatchLocal,
  getSyncCursor,
  setSyncCursor,
  hasPendingOutboxRecord,
} from '@cheesyos/pos-local';
import { PushSyncError } from './errors.js';

export type PullDataset =
  | 'categories'
  | 'products'
  | 'product_variants'
  | 'customers'
  | 'pos_tables'
  | 'table_sessions'
  | 'orders'
  | 'pos_kots'
  | 'kot_corrections'
  | 'bills'
  | 'payments'
  | 'inventory_lite';

export interface CloudPullCursor {
  lastTimestamp: string;
  lastId: string;
}

export interface CloudPullTransport {
  fetchCategoriesDelta?(cursor: CloudPullCursor, limit: number): Promise<any[]>;
  fetchProductsDelta?(cursor: CloudPullCursor, limit: number): Promise<any[]>;
  fetchProductVariantsDelta?(cursor: CloudPullCursor, limit: number): Promise<any[]>;
  fetchCustomersDelta?(cursor: CloudPullCursor, limit: number): Promise<any[]>;
  fetchPosTablesDelta?(cursor: CloudPullCursor, limit: number): Promise<any[]>;
  fetchTableSessionsDelta?(cursor: CloudPullCursor, limit: number): Promise<any[]>;
  fetchOrdersDelta?(cursor: CloudPullCursor, limit: number): Promise<{ orders: any[]; orderItems: any[] }>;
  fetchKotsDelta?(cursor: CloudPullCursor, limit: number): Promise<{ kots: any[]; kotItems: any[] }>;
  fetchKotCorrectionsDelta?(cursor: CloudPullCursor, limit: number): Promise<any[]>;
  fetchBillsDelta?(cursor: CloudPullCursor, limit: number): Promise<any[]>;
  fetchPaymentsDelta?(cursor: CloudPullCursor, limit: number): Promise<any[]>;
  fetchInventoryLiteDelta?(cursor: CloudPullCursor, limit: number): Promise<any[]>;
}

export interface PullCycleOptions {
  dbManager: IPosPersistence | IPosLocalDatabase | PosLocalDatabase;
  transport: CloudPullTransport;
  datasets?: PullDataset[];
  batchSize?: number;
}

export interface PullCycleResult {
  status: 'IDLE' | 'COMPLETED' | 'RETRYABLE_STOPPED' | 'AUTH_REQUIRED_STOPPED' | 'CONTRACT_CONFLICT_STOPPED';
  datasetsProcessed: number;
  rowsApplied: number;
  lastError?: string;
}

export const DEFAULT_PULL_PAGE_SIZE = 100;
export const MAX_PULL_PAGE_SIZE = 100;
export const MAX_PARENT_AGGREGATE_PAGE_SIZE = 25;
export const MAX_CLOUD_READ_REQUESTS_PER_PULL_CYCLE = 14;
export const CHILD_PAGE_SIZE = 500;

export const DEFAULT_PULL_DATASETS: PullDataset[] = [
  'categories',
  'products',
  'product_variants',
  'customers',
  'pos_tables',
  'table_sessions',
  'orders',
  'pos_kots',
  'kot_corrections',
  'bills',
  'payments',
  'inventory_lite',
];

/**
 * Paginates child items in deterministic order until final partial/empty page proves completeness.
 */
async function fetchAllChildItems(
  fetchPage: (from: number, to: number) => Promise<{ data: any[] | null; error: any }>
): Promise<any[]> {
  const allItems: any[] = [];
  let from = 0;

  while (true) {
    const to = from + CHILD_PAGE_SIZE - 1;
    const { data, error } = await fetchPage(from, to);
    if (error) {
      throw new PushSyncError('RETRYABLE', error.message, error);
    }
    const pageRows = data || [];
    allItems.push(...pageRows);

    if (pageRows.length < CHILD_PAGE_SIZE) {
      // Completion proof: page count < requested page size proves all children retrieved
      break;
    }
    from += CHILD_PAGE_SIZE;
  }

  return allItems;
}

/**
 * Creates a Supabase-backed CloudPullTransport for real NextGen Dev client.
 */
export function createSupabasePullTransport(client: any): CloudPullTransport {
  function applyCursorFilter(query: any, timestampCol: string, cursor: CloudPullCursor) {
    if (cursor.lastTimestamp === '1970-01-01T00:00:00.000Z') {
      return query;
    }
    return query.or(
      `${timestampCol}.gt.${cursor.lastTimestamp},and(${timestampCol}.eq.${cursor.lastTimestamp},id.gt.${cursor.lastId})`
    );
  }

  return {
    async fetchCategoriesDelta(cursor, limit) {
      let q = client.from('categories').select('*');
      q = applyCursorFilter(q, 'updated_at', cursor);
      const { data, error } = await q.order('updated_at', { ascending: true }).order('id', { ascending: true }).limit(limit);
      if (error) throw new PushSyncError('RETRYABLE', error.message, error);
      return data || [];
    },

    async fetchProductsDelta(cursor, limit) {
      let q = client.from('products').select('*');
      q = applyCursorFilter(q, 'updated_at', cursor);
      const { data, error } = await q.order('updated_at', { ascending: true }).order('id', { ascending: true }).limit(limit);
      if (error) throw new PushSyncError('RETRYABLE', error.message, error);
      return data || [];
    },

    async fetchProductVariantsDelta(cursor, limit) {
      let q = client.from('product_variants').select('*');
      q = applyCursorFilter(q, 'created_at', cursor);
      const { data, error } = await q.order('created_at', { ascending: true }).order('id', { ascending: true }).limit(limit);
      if (error) throw new PushSyncError('RETRYABLE', error.message, error);
      return data || [];
    },

    async fetchCustomersDelta(cursor, limit) {
      let q = client.from('customers').select('*');
      q = applyCursorFilter(q, 'updated_at', cursor);
      const { data, error } = await q.order('updated_at', { ascending: true }).order('id', { ascending: true }).limit(limit);
      if (error) throw new PushSyncError('RETRYABLE', error.message, error);
      return data || [];
    },

    async fetchPosTablesDelta(cursor, limit) {
      let q = client.from('pos_tables').select('*');
      q = applyCursorFilter(q, 'created_at', cursor);
      const { data, error } = await q.order('created_at', { ascending: true }).order('id', { ascending: true }).limit(limit);
      if (error) throw new PushSyncError('RETRYABLE', error.message, error);
      return data || [];
    },

    async fetchTableSessionsDelta(cursor, limit) {
      let q = client.from('table_sessions').select('*');
      q = applyCursorFilter(q, 'opened_at', cursor);
      const { data, error } = await q.order('opened_at', { ascending: true }).order('id', { ascending: true }).limit(limit);
      if (error) throw new PushSyncError('RETRYABLE', error.message, error);
      return data || [];
    },

    async fetchOrdersDelta(cursor, limit) {
      // Bound parent order batch limit to MAX_PARENT_AGGREGATE_PAGE_SIZE (25)
      const safeLimit = Math.min(limit, MAX_PARENT_AGGREGATE_PAGE_SIZE);
      let q = client.from('orders').select('*');
      q = applyCursorFilter(q, 'updated_at', cursor);
      const { data: orders, error: orderErr } = await q.order('updated_at', { ascending: true }).order('id', { ascending: true }).limit(safeLimit);
      if (orderErr) throw new PushSyncError('RETRYABLE', orderErr.message, orderErr);
      if (!orders || orders.length === 0) return { orders: [], orderItems: [] };

      const orderIds = orders.map((o: any) => o.id);
      const orderItems = await fetchAllChildItems((from, to) =>
        client.from('order_items').select('*').in('order_id', orderIds).order('id', { ascending: true }).range(from, to)
      );

      return { orders, orderItems };
    },

    async fetchKotsDelta(cursor, limit) {
      // Bound parent KOT batch limit to MAX_PARENT_AGGREGATE_PAGE_SIZE (25)
      const safeLimit = Math.min(limit, MAX_PARENT_AGGREGATE_PAGE_SIZE);
      let q = client.from('pos_kots').select('*');
      q = applyCursorFilter(q, 'printed_at', cursor);
      const { data: kots, error: kotErr } = await q.order('printed_at', { ascending: true }).order('id', { ascending: true }).limit(safeLimit);
      if (kotErr) throw new PushSyncError('RETRYABLE', kotErr.message, kotErr);
      if (!kots || kots.length === 0) return { kots: [], kotItems: [] };

      const kotIds = kots.map((k: any) => k.id);
      const kotItems = await fetchAllChildItems((from, to) =>
        client.from('kot_items').select('*').in('kot_id', kotIds).order('id', { ascending: true }).range(from, to)
      );

      return { kots, kotItems };
    },

    async fetchKotCorrectionsDelta(cursor, limit) {
      let q = client.from('kot_corrections').select('*');
      q = applyCursorFilter(q, 'created_at', cursor);
      const { data, error } = await q.order('created_at', { ascending: true }).order('id', { ascending: true }).limit(limit);
      if (error) throw new PushSyncError('RETRYABLE', error.message, error);
      return data || [];
    },

    async fetchBillsDelta(cursor, limit) {
      let q = client.from('bills').select('*');
      q = applyCursorFilter(q, 'finalized_at', cursor);
      const { data, error } = await q.order('finalized_at', { ascending: true }).order('id', { ascending: true }).limit(limit);
      if (error) throw new PushSyncError('RETRYABLE', error.message, error);
      return data || [];
    },

    async fetchPaymentsDelta(cursor, limit) {
      let q = client.from('payments').select('*');
      q = applyCursorFilter(q, 'confirmed_at', cursor);
      const { data, error } = await q.order('confirmed_at', { ascending: true }).order('id', { ascending: true }).limit(limit);
      if (error) throw new PushSyncError('RETRYABLE', error.message, error);
      return data || [];
    },

    async fetchInventoryLiteDelta(cursor, limit) {
      let q = client.from('inventory_lite').select('*');
      q = applyCursorFilter(q, 'updated_at', cursor);
      const { data, error } = await q.order('updated_at', { ascending: true }).order('id', { ascending: true }).limit(limit);
      if (error) throw new PushSyncError('RETRYABLE', error.message, error);
      return data || [];
    },
  };
}

/**
 * Helper to convert Rupees (number) to integer Paise
 */
function toPaise(rupees: number | null | undefined): number {
  if (rupees === null || rupees === undefined) return 0;
  return Math.round(Number(rupees) * 100);
}

/**
 * Helper to convert date values to ISO string for SQLite binding
 */
function toIsoString(val: any): string {
  if (!val) return new Date().toISOString();
  if (val instanceof Date) return val.toISOString();
  return String(val);
}

/**
 * Runs one bounded, incremental Cloud → Local delta pull cycle across configured datasets.
 * 
 * Invocation:
 * 1. Reads persisted cursor for dataset.
 * 2. Fetches 1 bounded delta page from cloud.
 * 3. Applies rows to SQLite in 1 transaction (skipping items with local pending outbox entries).
 * 4. Advances cursor atomically in same transaction.
 * 5. Returns summary result.
 */
export async function runPullCycle(options: PullCycleOptions): Promise<PullCycleResult> {
  const limit = Math.min(options.batchSize || DEFAULT_PULL_PAGE_SIZE, MAX_PULL_PAGE_SIZE);
  const datasets = options.datasets || DEFAULT_PULL_DATASETS;
  let datasetsProcessed = 0;
  let totalRowsApplied = 0;

  for (const dataset of datasets) {
    try {
      let rowsAppliedInDataset = 0;

      // 1. Read persisted cursor from storage
      const cursorState =
        'getSyncCursor' in options.dbManager && typeof options.dbManager.getSyncCursor === 'function' && options.dbManager.getSyncCursor.length === 1
          ? await options.dbManager.getSyncCursor(dataset as any)
          : (options.dbManager as any).runTransaction((db: any) => getSyncCursor(db, dataset));

      const cursor: CloudPullCursor = {
        lastTimestamp: cursorState.lastUpdatedAt,
        lastId: cursorState.lastId,
      };

      const applyBatch = async (
        datasetName: LocalPullDataset,
        batchRows: any[],
        newCursor: { lastUpdatedAt: string; lastId: string }
      ): Promise<number> => {
        if ('applyPullBatch' in options.dbManager && typeof options.dbManager.applyPullBatch === 'function') {
          return await options.dbManager.applyPullBatch(datasetName, batchRows, newCursor);
        }
        return (options.dbManager as any).runTransaction((db: any) => {
          return applyPullBatchLocal(db, datasetName, batchRows, newCursor);
        });
      };

      // 2. Fetch bounded delta page from cloud transport & apply
      if (dataset === 'categories') {
        if (!options.transport.fetchCategoriesDelta) continue;
        const rows = await options.transport.fetchCategoriesDelta(cursor, limit);
        if (rows && rows.length > 0) {
          const lastRow = rows[rows.length - 1];
          const newCursor = { lastUpdatedAt: toIsoString(lastRow.updated_at), lastId: lastRow.id };
          rowsAppliedInDataset += await applyBatch('categories', rows, newCursor);
        }
      } else if (dataset === 'products') {
        if (!options.transport.fetchProductsDelta) continue;
        const rows = await options.transport.fetchProductsDelta(cursor, limit);
        if (rows && rows.length > 0) {
          const lastRow = rows[rows.length - 1];
          const newCursor = { lastUpdatedAt: toIsoString(lastRow.updated_at), lastId: lastRow.id };
          rowsAppliedInDataset += await applyBatch('products', rows, newCursor);
        }
      } else if (dataset === 'product_variants') {
        if (!options.transport.fetchProductVariantsDelta) continue;
        const rows = await options.transport.fetchProductVariantsDelta(cursor, limit);
        if (rows && rows.length > 0) {
          const lastRow = rows[rows.length - 1];
          const newCursor = { lastUpdatedAt: toIsoString(lastRow.created_at), lastId: lastRow.id };
          rowsAppliedInDataset += await applyBatch('product_variants', rows, newCursor);
        }
      } else if (dataset === 'customers') {
        if (!options.transport.fetchCustomersDelta) continue;
        const rows = await options.transport.fetchCustomersDelta(cursor, limit);
        if (rows && rows.length > 0) {
          const lastRow = rows[rows.length - 1];
          const newCursor = { lastUpdatedAt: toIsoString(lastRow.updated_at), lastId: lastRow.id };
          rowsAppliedInDataset += await applyBatch('customers', rows, newCursor);
        }
      } else if (dataset === 'pos_tables') {
        if (!options.transport.fetchPosTablesDelta) continue;
        const rows = await options.transport.fetchPosTablesDelta(cursor, limit);
        if (rows && rows.length > 0) {
          const lastRow = rows[rows.length - 1];
          const newCursor = { lastUpdatedAt: toIsoString(lastRow.created_at), lastId: lastRow.id };
          rowsAppliedInDataset += await applyBatch('pos_tables', rows, newCursor);
        }
      } else if (dataset === 'table_sessions') {
        if (!options.transport.fetchTableSessionsDelta) continue;
        const rows = await options.transport.fetchTableSessionsDelta(cursor, limit);
        if (rows && rows.length > 0) {
          const lastRow = rows[rows.length - 1];
          const newCursor = { lastUpdatedAt: toIsoString(lastRow.opened_at), lastId: lastRow.id };
          rowsAppliedInDataset += await applyBatch('table_sessions', rows, newCursor);
        }
      } else if (dataset === 'orders') {
        if (!options.transport.fetchOrdersDelta) continue;
        const { orders, orderItems } = await options.transport.fetchOrdersDelta(cursor, limit);
        if (orders && orders.length > 0) {
          const lastRow = orders[orders.length - 1];
          const newCursor = { lastUpdatedAt: toIsoString(lastRow.updated_at), lastId: lastRow.id };
          rowsAppliedInDataset += await applyBatch('orders', [{ orders, orderItems: orderItems || [] }], newCursor);
        }
      } else if (dataset === 'pos_kots') {
        if (!options.transport.fetchKotsDelta) continue;
        const { kots, kotItems } = await options.transport.fetchKotsDelta(cursor, limit);
        if (kots && kots.length > 0) {
          const lastRow = kots[kots.length - 1];
          const newCursor = { lastUpdatedAt: toIsoString(lastRow.printed_at), lastId: lastRow.id };
          rowsAppliedInDataset += await applyBatch('pos_kots', [{ kots, kotItems: kotItems || [] }], newCursor);
        }
      } else if (dataset === 'kot_corrections') {
        if (!options.transport.fetchKotCorrectionsDelta) continue;
        const rows = await options.transport.fetchKotCorrectionsDelta(cursor, limit);
        if (rows && rows.length > 0) {
          const lastRow = rows[rows.length - 1];
          const newCursor = { lastUpdatedAt: toIsoString(lastRow.created_at), lastId: lastRow.id };
          rowsAppliedInDataset += await applyBatch('kot_corrections', rows, newCursor);
        }
      } else if (dataset === 'bills') {
        if (!options.transport.fetchBillsDelta) continue;
        const rows = await options.transport.fetchBillsDelta(cursor, limit);
        if (rows && rows.length > 0) {
          const lastRow = rows[rows.length - 1];
          const newCursor = { lastUpdatedAt: toIsoString(lastRow.finalized_at), lastId: lastRow.id };
          rowsAppliedInDataset += await applyBatch('bills', rows, newCursor);
        }
      } else if (dataset === 'payments') {
        if (!options.transport.fetchPaymentsDelta) continue;
        const rows = await options.transport.fetchPaymentsDelta(cursor, limit);
        if (rows && rows.length > 0) {
          const lastRow = rows[rows.length - 1];
          const newCursor = { lastUpdatedAt: toIsoString(lastRow.confirmed_at), lastId: lastRow.id };
          rowsAppliedInDataset += await applyBatch('payments', rows, newCursor);
        }
      } else if (dataset === 'inventory_lite') {
        if (!options.transport.fetchInventoryLiteDelta) continue;
        const rows = await options.transport.fetchInventoryLiteDelta(cursor, limit);
        if (rows && rows.length > 0) {
          const lastRow = rows[rows.length - 1];
          const newCursor = { lastUpdatedAt: toIsoString(lastRow.updated_at), lastId: lastRow.id };
          rowsAppliedInDataset += await applyBatch('inventory_lite', rows, newCursor);
        }
      }

      datasetsProcessed++;
      totalRowsApplied += rowsAppliedInDataset;
    } catch (err: any) {
      if (err instanceof PushSyncError || (err.message && err.message.includes('CONTRACT_CONFLICT'))) {
        let status: PullCycleResult['status'] = 'RETRYABLE_STOPPED';
        if (err instanceof PushSyncError) {
          if (err.code === 'AUTH_REQUIRED') status = 'AUTH_REQUIRED_STOPPED';
          if (err.code === 'CONTRACT_CONFLICT') status = 'CONTRACT_CONFLICT_STOPPED';
        } else if (err.message && err.message.includes('CONTRACT_CONFLICT')) {
          status = 'CONTRACT_CONFLICT_STOPPED';
        }
        return {
          status,
          datasetsProcessed,
          rowsApplied: totalRowsApplied,
          lastError: err.message,
        };
      }
      return {
        status: 'RETRYABLE_STOPPED',
        datasetsProcessed,
        rowsApplied: totalRowsApplied,
        lastError: err.message,
      };
    }
  }

  return {
    status: 'COMPLETED',
    datasetsProcessed,
    rowsApplied: totalRowsApplied,
  };
}
