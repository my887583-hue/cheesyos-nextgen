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
  replaceDraftOrder?(order: Record<string, unknown>, items: Array<Record<string, unknown>>): Promise<boolean>;
  syncKot(kot: Record<string, unknown>, items: Array<Record<string, unknown>>): Promise<boolean>;
  syncKotCorrection(
    correction: Record<string, unknown>,
    updatedOrderItem?: Record<string, unknown>,
    updatedOrder?: Record<string, unknown>
  ): Promise<boolean>;
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
  syncTableSession(session: Record<string, unknown>): Promise<boolean>;
  appendOrderItemsAndKot?(
    order: Record<string, unknown>,
    newOrderItems: Array<Record<string, unknown>>,
    kot: Record<string, unknown>,
    kotItems: Array<Record<string, unknown>>
  ): Promise<boolean>;
}

/**
 * Creates a Production-ready Cloud RPC Transport adapter wrapping NextGen Supabase client.
 */
export function createSupabasePushTransport(
  client: SupabaseClient<Database>
): CloudRpcTransport {
  return {
    async syncTableSession(session) {
      const { data, error } = await (client.rpc as any)('secure_sync_pos_table_session', {
        p_session: session,
      });
      if (error) {
        if (error.message.includes('CONTRACT_CONFLICT') || error.message.includes('VALIDATION_ERROR')) {
          throw new PushSyncError('CONTRACT_CONFLICT', error.message, error);
        }
        if (error.message.includes('Access Denied') || error.message.includes('DEVICE_REVOKED') || error.message.includes('DEVICE_AUTH_FAILED') || error.code === '42501') {
          throw new PushSyncError('AUTH_REQUIRED', error.message, error);
        }
        throw new PushSyncError('RETRYABLE', error.message, error);
      }
      return data ?? true;
    },

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

    async replaceDraftOrder(order, items) {
      const { data, error } = await (client.rpc as any)('secure_replace_pos_draft_order', {
        p_order: order,
        p_order_items: items,
      });
      if (error) {
        if (
          error.message.includes('CONTRACT_CONFLICT') ||
          error.message.includes('VALIDATION_ERROR') ||
          error.message.includes('VERSION_CONFLICT') ||
          error.message.includes('STALE_VERSION') ||
          error.message.includes('VERSION_GAP')
        ) {
          throw new PushSyncError('CONTRACT_CONFLICT', error.message, error);
        }
        if (
          error.message.includes('Access Denied') ||
          error.message.includes('DEVICE_REVOKED') ||
          error.message.includes('DEVICE_AUTH_FAILED') ||
          error.code === '42501'
        ) {
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

    async syncKotCorrection(correction, updatedOrderItem, updatedOrder) {
      if (updatedOrderItem && updatedOrder) {
        const { data, error } = await (client.rpc as any)('secure_save_kot_correction', {
          p_correction: correction,
          p_updated_order_item: updatedOrderItem,
          p_updated_order: updatedOrder,
        });
        if (error) {
          if (
            error.message.includes('CONTRACT_CONFLICT') ||
            error.message.includes('VALIDATION_ERROR') ||
            error.message.includes('IDEMPOTENCY_CONFLICT') ||
            error.message.includes('ORDER_ITEM_NOT_FOUND') ||
            error.message.includes('KOT_ITEM_NOT_FOUND') ||
            error.message.includes('CORRECTION_LINEAGE_UNAVAILABLE')
          ) {
            throw new PushSyncError('CONTRACT_CONFLICT', error.message, error);
          }
          if (
            error.message.includes('Access Denied') ||
            error.message.includes('DEVICE_REVOKED') ||
            error.message.includes('DEVICE_AUTH_FAILED') ||
            error.code === '42501'
          ) {
            throw new PushSyncError('AUTH_REQUIRED', error.message, error);
          }
          throw new PushSyncError('RETRYABLE', error.message, error);
        }
        return data ?? true;
      }

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

    async appendOrderItemsAndKot(order, newOrderItems, kot, kotItems) {
      const { data, error } = await (client.rpc as any)('secure_append_pos_order_items_and_kot', {
        p_order: order,
        p_order_items: newOrderItems,
        p_kot: kot,
        p_kot_items: kotItems,
      });
      if (error) {
        if (
          error.message.includes('CONTRACT_CONFLICT') ||
          error.message.includes('VALIDATION_ERROR') ||
          error.message.includes('IDEMPOTENCY_CONFLICT') ||
          error.message.includes('NUMBERING_CONFLICT')
        ) {
          throw new PushSyncError('CONTRACT_CONFLICT', error.message, error);
        }
        if (
          error.message.includes('Access Denied') ||
          error.message.includes('DEVICE_REVOKED') ||
          error.message.includes('DEVICE_AUTH_FAILED') ||
          error.code === '42501'
        ) {
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
        if (row.operation === 'UPDATE') {
          if (typeof options.transport.replaceDraftOrder === 'function') {
            await options.transport.replaceDraftOrder(orderData, itemsData);
          } else {
            throw new PushSyncError('QUEUE_CONFLICT', 'Transport does not implement replaceDraftOrder for draft order UPDATE');
          }
        } else {
          await options.transport.syncOrder(orderData, itemsData);
        }
      } else if (row.entity_type === 'table_sessions') {
        const sessionData = payload.session || payload;
        await options.transport.syncTableSession(sessionData);
      } else if (row.entity_type === 'pos_kots') {
        // KOT aggregate payload: { kot, items, orderItems?, order? }
        const kotData = payload.kot || payload;
        const itemsData = payload.items || [];
        const orderItemsData = payload.orderItems || payload.order_items;
        const orderData = payload.order;

        if (orderItemsData && Array.isArray(orderItemsData) && orderItemsData.length > 0 && orderData) {
          if (typeof options.transport.appendOrderItemsAndKot === 'function') {
            await options.transport.appendOrderItemsAndKot(orderData, orderItemsData, kotData, itemsData);
          } else {
            throw new PushSyncError('QUEUE_CONFLICT', 'Transport does not implement appendOrderItemsAndKot for additional KOT');
          }
        } else {
          await options.transport.syncKot(kotData, itemsData);
        }
      } else if (row.entity_type === 'kot_corrections') {
        const correctionData = payload.correction || payload;
        const updatedOrderItemData = payload.updatedOrderItem;
        const updatedOrderData = payload.updatedOrder;
        await options.transport.syncKotCorrection(correctionData, updatedOrderItemData, updatedOrderData);
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
