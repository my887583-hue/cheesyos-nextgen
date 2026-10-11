/**
 * CHEESYOS NEXTGEN POS SYNC — BOUNDED DURABLE PUSH WORKER
 * 
 * Executes explicit bounded push cycles from local SQLite sync_outbox to NextGen cloud RPCs.
 */

import { SupabaseClient } from '@supabase/supabase-js';
import type { Database } from '@cheesyos/nextgen-shared';
import {
  PosLocalDatabase,
  IPosLocalDatabase,
  IPosPersistence,
  getPendingOutboxEntries,
  acknowledgeOutboxRecord,
  updateOutboxRecordFailure,
  OutboxRow
} from '@cheesyos/pos-local';
import { PushSyncError, PushSyncErrorCode } from './errors.js';

export const DEFAULT_PUSH_BATCH_SIZE = 10;
export const MAX_PUSH_BATCH_SIZE = 10;

export interface CloudRpcTransport {
  syncOrder(order: Record<string, unknown>, items: Array<Record<string, unknown>>): Promise<boolean>;
  syncKot(kot: Record<string, unknown>, items: Array<Record<string, unknown>>): Promise<boolean>;
  syncKotCorrection(correction: Record<string, unknown>): Promise<boolean>;
  syncBill(bill: Record<string, unknown>): Promise<boolean>;
  syncPayment(payment: Record<string, unknown>): Promise<boolean>;
  applyInventoryMovement(input: {
    productId: string;
    movementType: string;
    quantityChange: number;
    createdByStaffId?: string | null;
    movementId?: string;
    referenceMovementId?: string | null;
  }): Promise<boolean>;
}

/**
 * Creates a Production-ready Cloud RPC Transport adapter wrapping NextGen Supabase client.
 */
export function createSupabasePushTransport(
  client: SupabaseClient<Database>
): CloudRpcTransport {
  return {
    async syncOrder(order, items) {
      const { data, error } = await client.rpc('secure_sync_pos_order', {
        p_order: order,
        p_order_items: items,
      });
      if (error) {
        if (error.message.includes('CONTRACT_CONFLICT')) {
          throw new PushSyncError('CONTRACT_CONFLICT', error.message, error);
        }
        if (error.message.includes('Access Denied') || error.message.includes('DEVICE_REVOKED') || error.message.includes('DEVICE_AUTH_FAILED') || error.code === '42501') {
          throw new PushSyncError('AUTH_REQUIRED', error.message, error);
        }
        throw new PushSyncError('RETRYABLE', error.message, error);
      }
      return data ?? true;
    },

    async syncKot(kot, items) {
      const { data, error } = await client.rpc('secure_sync_pos_kot', {
        p_kot: kot,
        p_kot_items: items,
      });
      if (error) {
        if (error.message.includes('CONTRACT_CONFLICT')) {
          throw new PushSyncError('CONTRACT_CONFLICT', error.message, error);
        }
        if (error.message.includes('Access Denied') || error.message.includes('DEVICE_REVOKED') || error.message.includes('DEVICE_AUTH_FAILED') || error.code === '42501') {
          throw new PushSyncError('AUTH_REQUIRED', error.message, error);
        }
        throw new PushSyncError('RETRYABLE', error.message, error);
      }
      return data ?? true;
    },

    async syncKotCorrection(correction) {
      const { data, error } = await client.rpc('secure_sync_kot_correction', {
        p_correction: correction,
      });
      if (error) {
        if (error.message.includes('CONTRACT_CONFLICT')) {
          throw new PushSyncError('CONTRACT_CONFLICT', error.message, error);
        }
        if (error.message.includes('Access Denied') || error.message.includes('DEVICE_REVOKED') || error.message.includes('DEVICE_AUTH_FAILED') || error.code === '42501') {
          throw new PushSyncError('AUTH_REQUIRED', error.message, error);
        }
        throw new PushSyncError('RETRYABLE', error.message, error);
      }
      return data ?? true;
    },

    async syncBill(bill) {
      const { data, error } = await client.rpc('secure_sync_pos_bill', {
        p_bill: bill,
      });
      if (error) {
        if (error.message.includes('CONTRACT_CONFLICT')) {
          throw new PushSyncError('CONTRACT_CONFLICT', error.message, error);
        }
        if (error.message.includes('Access Denied') || error.message.includes('DEVICE_REVOKED') || error.message.includes('DEVICE_AUTH_FAILED') || error.code === '42501') {
          throw new PushSyncError('AUTH_REQUIRED', error.message, error);
        }
        throw new PushSyncError('RETRYABLE', error.message, error);
      }
      return data ?? true;
    },

    async syncPayment(payment) {
      const { data, error } = await client.rpc('secure_sync_pos_payment', {
        p_payment: payment,
      });
      if (error) {
        if (error.message.includes('CONTRACT_CONFLICT') || error.message.includes('Overpayment Denied')) {
          throw new PushSyncError('CONTRACT_CONFLICT', error.message, error);
        }
        if (error.message.includes('Access Denied') || error.message.includes('DEVICE_REVOKED') || error.message.includes('DEVICE_AUTH_FAILED') || error.code === '42501') {
          throw new PushSyncError('AUTH_REQUIRED', error.message, error);
        }
        throw new PushSyncError('RETRYABLE', error.message, error);
      }
      return data ?? true;
    },

    async applyInventoryMovement(input) {
      const { data, error } = await client.rpc('secure_apply_inventory_movement', {
        p_product_id: input.productId,
        p_movement_type: input.movementType,
        p_quantity_change: input.quantityChange,
        p_created_by: input.createdByStaffId ?? undefined,
        p_movement_id: input.movementId,
        p_reference_movement_id: input.referenceMovementId ?? undefined,
      });
      if (error) {
        if (error.message.includes('Restoration Over-Credit Denied') || error.message.includes('Insufficient stock')) {
          throw new PushSyncError('CONTRACT_CONFLICT', error.message, error);
        }
        if (error.message.includes('Access Denied') || error.message.includes('DEVICE_REVOKED') || error.message.includes('DEVICE_AUTH_FAILED') || error.code === '42501') {
          throw new PushSyncError('AUTH_REQUIRED', error.message, error);
        }
        throw new PushSyncError('RETRYABLE', error.message, error);
      }
      return data ?? true;
    }
  };
}

export interface PushCycleOptions {
  dbManager: IPosPersistence | IPosLocalDatabase | PosLocalDatabase;
  transport: CloudRpcTransport;
  batchSize?: number;
}

export interface PushCycleResult {
  processedCount: number;
  successCount: number;
  status: 'IDLE' | 'COMPLETED' | 'RETRYABLE_STOPPED' | 'AUTH_REQUIRED_STOPPED' | 'CONTRACT_CONFLICT_STOPPED' | 'QUEUE_CONFLICT_STOPPED';
  lastError?: string;
}

/**
 * Single explicit bounded push execution cycle.
 * Bounded by batchSize (Max 10), processes sequentially, stops at first failure.
 */
export async function runPushCycle(options: PushCycleOptions): Promise<PushCycleResult> {
  const batchLimit = Math.min(options.batchSize || DEFAULT_PUSH_BATCH_SIZE, MAX_PUSH_BATCH_SIZE);
  
  // 1. Read pending outbox rows from storage
  const pendingRows = 'getPendingOutbox' in options.dbManager && typeof options.dbManager.getPendingOutbox === 'function'
    ? await options.dbManager.getPendingOutbox(batchLimit)
    : (options.dbManager as IPosLocalDatabase).runTransaction((db) => {
        return getPendingOutboxEntries(db, batchLimit);
      });

  if (pendingRows.length === 0) {
    return { processedCount: 0, successCount: 0, status: 'IDLE' };
  }

  let processedCount = 0;
  let successCount = 0;

  // 2. Sequential processing loop
  for (const row of pendingRows) {
    processedCount++;

    // Child event safety check: orphan order_items / kot_items cannot generate direct cloud writes
    if (row.entity_type === 'order_items' || row.entity_type === 'kot_items') {
      const parentType = row.entity_type === 'order_items' ? 'orders' : 'pos_kots';
      const hasParentInBatch = pendingRows.some(r => r.entity_type === parentType);
      if (!hasParentInBatch) {
        // Child row without parent in outbox queue
        const errMessage = `QUEUE_CONFLICT: Orphan child outbox row ${row.entity_type} (ID: ${row.entity_id}) cannot be pushed independently`;
        if ('updateOutboxFailure' in options.dbManager && typeof options.dbManager.updateOutboxFailure === 'function') {
          await options.dbManager.updateOutboxFailure(row.seq, errMessage);
        } else {
          (options.dbManager as IPosLocalDatabase).runTransaction((db) => {
            updateOutboxRecordFailure(db, row.seq, errMessage);
          });
        }
        return {
          processedCount,
          successCount,
          status: 'QUEUE_CONFLICT_STOPPED',
          lastError: errMessage,
        };
      }
      // Skip independent child row — handled during root parent aggregate processing
      continue;
    }

    try {
      const payload = JSON.parse(row.payload_json);

      if (row.entity_type === 'orders') {
        // Order aggregate payload: { order, items }
        const orderData = payload.order || payload;
        const itemsData = payload.items || [];
        await options.transport.syncOrder(orderData, itemsData);
      } else if (row.entity_type === 'pos_kots') {
        // KOT aggregate payload: { kot, items }
        const kotData = payload.kot || payload;
        const itemsData = payload.items || [];
        await options.transport.syncKot(kotData, itemsData);
      } else if (row.entity_type === 'kot_corrections') {
        const correctionData = payload.correction || payload;
        await options.transport.syncKotCorrection(correctionData);
      } else if (row.entity_type === 'bills') {
        const billData = payload.bill || payload;
        await options.transport.syncBill(billData);
      } else if (row.entity_type === 'payments') {
        const paymentData = payload.payment || payload;
        await options.transport.syncPayment(paymentData);
      } else if (row.entity_type === 'inventory_movements' || row.entity_type === 'inventory_movement') {
        await options.transport.applyInventoryMovement({
          productId: payload.productId,
          movementType: payload.movementType,
          quantityChange: payload.quantityChange,
          createdByStaffId: payload.createdByStaffId,
          movementId: payload.movementId || row.entity_id,
          referenceMovementId: payload.referenceMovementId,
        });
      } else {
        throw new PushSyncError('QUEUE_CONFLICT', `Unsupported outbox entity_type: ${row.entity_type}`);
      }

      // 3. Atomic Local ACK after cloud confirmation
      if ('acknowledgeOutbox' in options.dbManager && typeof options.dbManager.acknowledgeOutbox === 'function') {
        await options.dbManager.acknowledgeOutbox(row.seq);
        if (row.entity_type === 'orders') {
          const childRows = pendingRows.filter(r => r.entity_type === 'order_items');
          for (const cr of childRows) {
            await options.dbManager.acknowledgeOutbox(cr.seq);
          }
        } else if (row.entity_type === 'pos_kots') {
          const childRows = pendingRows.filter(r => r.entity_type === 'kot_items');
          for (const cr of childRows) {
            await options.dbManager.acknowledgeOutbox(cr.seq);
          }
        }
      } else {
        (options.dbManager as IPosLocalDatabase).runTransaction((db) => {
          acknowledgeOutboxRecord(db, row.seq);
          // Also ACK any associated child outbox rows if parent aggregate
          if (row.entity_type === 'orders') {
            const childRows = pendingRows.filter(r => r.entity_type === 'order_items');
            for (const cr of childRows) {
              acknowledgeOutboxRecord(db, cr.seq);
            }
          } else if (row.entity_type === 'pos_kots') {
            const childRows = pendingRows.filter(r => r.entity_type === 'kot_items');
            for (const cr of childRows) {
              acknowledgeOutboxRecord(db, cr.seq);
            }
          }
        });
      }

      successCount++;
    } catch (err: any) {
      const code: PushSyncErrorCode = err instanceof PushSyncError ? err.code : 'RETRYABLE';
      const errMsg = err.message || String(err);

      // Record failure metadata in SQLite outbox
      if ('updateOutboxFailure' in options.dbManager && typeof options.dbManager.updateOutboxFailure === 'function') {
        await options.dbManager.updateOutboxFailure(row.seq, errMsg);
      } else {
        (options.dbManager as IPosLocalDatabase).runTransaction((db) => {
          updateOutboxRecordFailure(db, row.seq, errMsg);
        });
      }

      let status: PushCycleResult['status'] = 'RETRYABLE_STOPPED';
      if (code === 'AUTH_REQUIRED') status = 'AUTH_REQUIRED_STOPPED';
      if (code === 'CONTRACT_CONFLICT') status = 'CONTRACT_CONFLICT_STOPPED';
      if (code === 'QUEUE_CONFLICT') status = 'QUEUE_CONFLICT_STOPPED';

      // STOP_AT_FIRST_FAILURE invariant
      return {
        processedCount,
        successCount,
        status,
        lastError: errMsg,
      };
    }
  }

  return {
    processedCount,
    successCount,
    status: 'COMPLETED',
  };
}
