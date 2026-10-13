/**
 * CHEESYOS NEXTGEN POS HOST — TAURI DESKTOP NATIVE PERSISTENCE ADAPTER
 * 
 * Implements the verified asynchronous semantic persistence contract (IPosPersistence).
 * Bridges renderer operations to the native Rust SQLite engine via secure, finite Tauri IPC commands.
 * 
 * SECURITY INVARIANTS:
 * - Direct implementation of IPosPersistence (zero generic SQL statements).
 * - Zero raw SQL strings or table names sent across Tauri IPC boundary.
 * - Zero mockStorage, zero fake statements in production persistence.
 * - Zero node:sqlite imports in renderer bundle.
 */

import type {
  OrderDomain,
  OrderItemDomain,
  PosKotDomain,
  KotItemDomain,
  KotCorrectionDomain,
  BillDomain,
  PaymentDomain,
  TableSessionDomain,
} from '@cheesyos/nextgen-shared';
import type {
  IPosPersistence,
  LocalDeviceConfigInput,
  LocalDeviceConfig,
  OutboxRow,
  SyncCursor,
  PullDataset,
  SaveOrderResult,
  SaveKotResult,
  AppendOrderItemsAndKotResult,
  SaveBillWithSequenceResult,
  SavePaymentResult,
  SaveInventoryMovementInput,
  SaveInventoryMovementResult,
  TableWithActiveSession,
  PosCatalog,
  ActiveTableOrderResult,
  LocalBill,
  TableOccupancyStatus,
  ApplyKotCorrectionInput,
  ApplyKotCorrectionLocalResult,
  OrderKotHeaderWithItems,
} from '@cheesyos/pos-local';
import { toPaise } from '@cheesyos/pos-core';
import type { CloudRpcTransport } from '@cheesyos/pos-sync';
import { PushSyncError } from '@cheesyos/pos-sync';

export type TauriInvokeHandler = (cmd: string, args?: Record<string, unknown>) => Promise<any>;

export type CommittedWriteListener = (entityType: string) => void;

/**
 * Resolves runtime Tauri invoke function from window environment.
 */
function resolveTauriInvoke(): TauriInvokeHandler {
  if (typeof window !== 'undefined') {
    const w = window as any;
    if (w.__TAURI_INTERNALS__?.invoke) {
      return w.__TAURI_INTERNALS__.invoke.bind(w.__TAURI_INTERNALS__);
    }
    if (w.__TAURI__?.core?.invoke) {
      return w.__TAURI__.core.invoke.bind(w.__TAURI__.core);
    }
  }
  return async (cmd: string, _args?: Record<string, unknown>) => {
    throw new Error(`[TauriPosPersistence] Native Tauri IPC is not available in this environment (cmd: ${cmd}).`);
  };
}

export class TauriPosPersistence implements IPosPersistence {
  private invoke: TauriInvokeHandler;
  private committedWriteListeners: Set<CommittedWriteListener> = new Set();

  constructor(invokeHandler?: TauriInvokeHandler) {
    this.invoke = invokeHandler || resolveTauriInvoke();
  }

  /**
   * Subscribes to local committed write events. Fired strictly after successful SQLite native commit.
   */
  public onCommittedWrite(listener: CommittedWriteListener): () => void {
    this.committedWriteListeners.add(listener);
    return () => {
      this.committedWriteListeners.delete(listener);
    };
  }

  private notifyCommittedWrite(entityType: string): void {
    for (const listener of this.committedWriteListeners) {
      try {
        listener(entityType);
      } catch (err) {
        console.error('[TauriPosPersistence] Error in committed write listener:', err);
      }
    }
  }

  /**
   * Initializes the native SQLite database schema and foreign keys in the Windows app-data boundary.
   */
  public async initSchema(): Promise<string> {
    return await this.invoke('init_db_schema');
  }

  // --- 1 & 2: Device Config ---

  public async getDeviceConfig(): Promise<LocalDeviceConfig | null> {
    const res = await this.invoke('pos_db_query', {
      query: { type: 'GetDeviceConfig' },
    });
    return res ? (res as LocalDeviceConfig) : null;
  }

  public async setDeviceConfig(config: LocalDeviceConfigInput): Promise<LocalDeviceConfig> {
    const res = await this.invoke('pos_db_execute', {
      op: {
        type: 'SetDeviceConfig',
        payload: {
          device_id: config.device_id,
          terminal_code: config.terminal_code,
          device_name: config.device_name,
          created_at: config.created_at || null,
        },
      },
    });
    return res as LocalDeviceConfig;
  }

  // --- 3: Order Aggregate ---

  public async saveOrderAggregate(order: OrderDomain, items: OrderItemDomain[]): Promise<SaveOrderResult> {
    const orderPayload = {
      id: order.id,
      display_number: order.display_number || null,
      channel: order.channel,
      order_type: order.order_type,
      customer_id: order.customer_id || null,
      table_session_id: order.table_session_id || null,
      status: order.status,
      subtotal_paise: toPaise(order.subtotal),
      tax_total_paise: toPaise(order.tax_total),
      discount_total_paise: toPaise(order.discount_total),
      delivery_charge_paise: toPaise(order.delivery_charge),
      grand_total_paise: toPaise(order.grand_total),
      device_id: order.device_id || null,
      version: order.version ?? 1,
      created_at: order.created_at,
      updated_at: order.updated_at,
    };

    const itemsPayload = items.map((item) => ({
      id: item.id,
      order_id: item.order_id,
      product_id: item.product_id,
      variant_id: item.variant_id || null,
      product_name: item.product_name,
      unit_price_paise: toPaise(item.unit_price),
      quantity: item.quantity,
      tax_rate: item.tax_rate,
      discount_amount_paise: toPaise(item.discount_amount),
      line_total_paise: toPaise(item.line_total),
      notes: item.notes || null,
      created_at: item.created_at,
    }));

    const res = await this.invoke('pos_db_execute', {
      op: {
        type: 'SaveOrderAggregate',
        payload: {
          order: orderPayload,
          items: itemsPayload,
        },
      },
    });

    this.notifyCommittedWrite('orders');

    return {
      order,
      items,
      outboxEntries: res.outbox_entries || [],
    };
  }

  public async replaceDraftOrderAggregate(order: OrderDomain, items: OrderItemDomain[]): Promise<SaveOrderResult> {
    const orderPayload = {
      id: order.id,
      display_number: order.display_number || null,
      channel: order.channel,
      order_type: order.order_type,
      customer_id: order.customer_id || null,
      table_session_id: order.table_session_id || null,
      status: order.status,
      subtotal_paise: toPaise(order.subtotal),
      tax_total_paise: toPaise(order.tax_total),
      discount_total_paise: toPaise(order.discount_total),
      delivery_charge_paise: toPaise(order.delivery_charge),
      grand_total_paise: toPaise(order.grand_total),
      device_id: order.device_id || null,
      version: order.version,
      created_at: order.created_at,
      updated_at: order.updated_at,
    };

    const itemsPayload = items.map((item) => ({
      id: item.id,
      order_id: item.order_id,
      product_id: item.product_id,
      variant_id: item.variant_id || null,
      product_name: item.product_name,
      unit_price_paise: toPaise(item.unit_price),
      quantity: item.quantity,
      tax_rate: item.tax_rate,
      discount_amount_paise: toPaise(item.discount_amount),
      line_total_paise: toPaise(item.line_total),
      notes: item.notes || null,
      created_at: item.created_at,
    }));

    const res = await this.invoke('pos_db_execute', {
      op: {
        type: 'ReplaceDraftOrderAggregate',
        payload: {
          order: orderPayload,
          items: itemsPayload,
        },
      },
    });

    this.notifyCommittedWrite('orders');

    return {
      order: {
        ...order,
        version: res?.order?.version ?? order.version,
        updated_at: res?.order?.updated_at ?? order.updated_at,
      },
      items,
      outboxEntries: res?.outbox_entries || [],
    };
  }

  // --- 4 & 5: KOT Aggregate & Correction ---

  public async saveKotAggregate(kot: PosKotDomain, items: KotItemDomain[]): Promise<SaveKotResult> {
    const kotPayload = {
      id: kot.id,
      order_id: kot.order_id,
      kot_number: kot.kot_number,
      device_id: kot.device_id || null,
      status: kot.status,
      printed_at: kot.printed_at,
    };

    const itemsPayload = items.map((item) => ({
      id: item.id,
      kot_id: item.kot_id,
      product_id: item.product_id,
      variant_id: item.variant_id || null,
      product_name: item.product_name,
      quantity: item.quantity,
      notes: item.notes || null,
    }));

    const res = await this.invoke('pos_db_execute', {
      op: {
        type: 'SaveKotAggregate',
        payload: {
          kot: kotPayload,
          items: itemsPayload,
        },
      },
    });

    this.notifyCommittedWrite('pos_kots');

    return {
      kot,
      items,
      outboxEntries: res.outbox_entries || [],
    };
  }

  public async appendOrderItemsAndKot(
    order: OrderDomain,
    newItems: OrderItemDomain[],
    kot: PosKotDomain,
    kotItems: KotItemDomain[]
  ): Promise<AppendOrderItemsAndKotResult> {
    const orderPayload = {
      id: order.id,
      display_number: order.display_number || null,
      channel: order.channel,
      order_type: order.order_type,
      customer_id: order.customer_id || null,
      table_session_id: order.table_session_id || null,
      status: order.status,
      subtotal: order.subtotal,
      tax_total: order.tax_total,
      discount_total: order.discount_total,
      delivery_charge: order.delivery_charge,
      grand_total: order.grand_total,
      device_id: order.device_id || null,
      version: order.version || 1,
      created_at: order.created_at,
      updated_at: order.updated_at,
    };

    const newItemsPayload = newItems.map((item) => ({
      id: item.id,
      order_id: item.order_id,
      product_id: item.product_id,
      variant_id: item.variant_id || null,
      product_name: item.product_name,
      unit_price: item.unit_price,
      quantity: item.quantity,
      tax_rate: item.tax_rate,
      discount_amount: item.discount_amount,
      line_total: item.line_total,
      notes: item.notes || null,
      created_at: item.created_at,
    }));

    const kotPayload = {
      id: kot.id,
      order_id: kot.order_id,
      kot_number: kot.kot_number,
      device_id: kot.device_id || null,
      status: kot.status,
      printed_at: kot.printed_at,
    };

    const kotItemsPayload = kotItems.map((item) => ({
      id: item.id,
      kot_id: item.kot_id,
      product_id: item.product_id,
      variant_id: item.variant_id || null,
      product_name: item.product_name,
      quantity: item.quantity,
      notes: item.notes || null,
    }));

    const res = await this.invoke('pos_db_execute', {
      op: {
        type: 'AppendOrderItemsAndKot',
        payload: {
          order: orderPayload,
          new_items: newItemsPayload,
          kot: kotPayload,
          kot_items: kotItemsPayload,
        },
      },
    });

    this.notifyCommittedWrite('pos_kots');

    return {
      order: res?.order ?? order,
      newItems: res?.new_items ?? newItems,
      kot: res?.kot ?? kot,
      kotItems: res?.kot_items ?? kotItems,
      outboxEntries: res?.outbox_entries || [],
    };
  }

  public async saveKotCorrection(correction: KotCorrectionDomain): Promise<OutboxRow> {
    const correctionPayload = {
      id: correction.id,
      order_id: correction.order_id,
      kot_id: correction.kot_id || null,
      product_name: correction.product_name,
      cancelled_qty: correction.cancelled_qty,
      reason: correction.reason,
      authorized_by_staff_id: correction.authorized_by_staff_id,
      created_at: correction.created_at,
    };

    const res = await this.invoke('pos_db_execute', {
      op: {
        type: 'SaveKotCorrection',
        payload: correctionPayload,
      },
    });

    this.notifyCommittedWrite('kot_corrections');

    return res as OutboxRow;
  }

  public async applyKotCorrection(input: ApplyKotCorrectionInput): Promise<ApplyKotCorrectionLocalResult> {
    const correctionPayload = {
      id: input.correction.id,
      order_id: input.correction.order_id,
      kot_id: input.correction.kot_id || null,
      kot_item_id: input.correction.kot_item_id || null,
      order_item_id: input.correction.order_item_id || null,
      product_name: input.correction.product_name,
      cancelled_qty: input.correction.cancelled_qty,
      reason: input.correction.reason,
      authorized_by_staff_id: input.correction.authorized_by_staff_id,
      created_at: input.correction.created_at,
    };

    const updatedOrderItemPayload = {
      id: input.updatedOrderItem.id,
      order_id: input.updatedOrderItem.order_id,
      product_id: input.updatedOrderItem.product_id,
      variant_id: input.updatedOrderItem.variant_id ?? null,
      product_name: input.updatedOrderItem.product_name,
      unit_price_paise: toPaise(input.updatedOrderItem.unit_price),
      quantity: input.updatedOrderItem.quantity,
      tax_rate: input.updatedOrderItem.tax_rate ?? 5.0,
      discount_amount_paise: toPaise(input.updatedOrderItem.discount_amount ?? 0),
      line_total_paise: toPaise(input.updatedOrderItem.line_total),
      notes: input.updatedOrderItem.notes ?? null,
      created_at: input.updatedOrderItem.created_at,
    };

    const updatedOrderPayload = {
      id: input.updatedOrder.id,
      display_number: input.updatedOrder.display_number ?? null,
      channel: input.updatedOrder.channel,
      order_type: input.updatedOrder.order_type,
      customer_id: input.updatedOrder.customer_id ?? null,
      table_session_id: input.updatedOrder.table_session_id ?? null,
      status: input.updatedOrder.status,
      subtotal_paise: toPaise(input.updatedOrder.subtotal),
      tax_total_paise: toPaise(input.updatedOrder.tax_total),
      discount_total_paise: toPaise(input.updatedOrder.discount_total),
      delivery_charge_paise: toPaise(input.updatedOrder.delivery_charge),
      grand_total_paise: toPaise(input.updatedOrder.grand_total),
      device_id: input.updatedOrder.device_id ?? null,
      version: input.updatedOrder.version,
      created_at: input.updatedOrder.created_at,
      updated_at: input.updatedOrder.updated_at,
    };

    const res = await this.invoke('pos_db_execute', {
      op: {
        type: 'ApplyKotCorrection',
        payload: {
          correction: correctionPayload,
          updated_order_item: updatedOrderItemPayload,
          updated_order: updatedOrderPayload,
        },
      },
    }) as any;

    this.notifyCommittedWrite('kot_corrections');

    return {
      correction: input.correction,
      updatedOrderItem: input.updatedOrderItem,
      updatedOrder: input.updatedOrder,
      outboxEntry: res?.outbox_entries?.[0] || res?.outbox_entry || {
        seq: 0,
        id: '',
        entity_type: 'kot_corrections',
        entity_id: input.correction.id,
        operation: 'INSERT',
        payload_json: '',
        created_at: input.correction.created_at,
        attempt_count: 0,
        next_attempt_at: null,
        last_error: null,
      },
    };
  }

  // --- 6: Bill with Atomic Sequence Allocation ---

  public async saveBillWithSequence(bill: BillDomain): Promise<SaveBillWithSequenceResult> {
    const billPayload = {
      id: bill.id,
      order_id: bill.order_id,
      bill_number: bill.bill_number,
      subtotal_paise: toPaise(bill.subtotal),
      cgst_total_paise: toPaise(bill.cgst_total),
      sgst_total_paise: toPaise(bill.sgst_total),
      discount_total_paise: toPaise(bill.discount_total),
      grand_total_paise: toPaise(bill.grand_total),
      payment_status: bill.payment_status,
      finalized_at: bill.finalized_at,
      device_id: bill.device_id || null,
    };

    const res = await this.invoke('pos_db_execute', {
      op: {
        type: 'SaveBillWithSequence',
        payload: billPayload,
      },
    });

    this.notifyCommittedWrite('bills');

    return {
      bill: {
        ...bill,
        bill_number: res.bill.bill_number,
        device_id: res.bill.device_id || bill.device_id,
      },
      sequenceNumber: res.sequence_number,
      outboxEntry: res.outbox_entry,
    };
  }

  // --- 7 & 8: Payment & Inventory Movement ---

  public async savePayment(payment: PaymentDomain, updatedBill: BillDomain): Promise<SavePaymentResult> {
    const paymentPayload = {
      id: payment.id,
      bill_id: payment.bill_id,
      order_id: payment.order_id,
      payment_mode: payment.payment_mode,
      amount_paid_paise: toPaise(payment.amount_paid),
      confirmed_by_staff_id: payment.confirmed_by_staff_id || null,
      confirmed_at: payment.confirmed_at,
      notes: payment.notes || null,
    };

    const updatedBillPayload = {
      id: updatedBill.id,
      order_id: updatedBill.order_id,
      bill_number: updatedBill.bill_number,
      subtotal_paise: toPaise(updatedBill.subtotal),
      cgst_total_paise: toPaise(updatedBill.cgst_total),
      sgst_total_paise: toPaise(updatedBill.sgst_total),
      discount_total_paise: toPaise(updatedBill.discount_total),
      grand_total_paise: toPaise(updatedBill.grand_total),
      payment_status: updatedBill.payment_status,
      finalized_at: updatedBill.finalized_at,
      device_id: updatedBill.device_id || null,
    };

    const res = await this.invoke('pos_db_execute', {
      op: {
        type: 'SavePayment',
        payload: {
          payment: paymentPayload,
          updated_bill: updatedBillPayload,
        },
      },
    });

    this.notifyCommittedWrite('payments');

    return {
      payment,
      updatedBill,
      outboxEntry: res.outbox_entry,
    };
  }

  public async saveInventoryMovement(input: SaveInventoryMovementInput): Promise<SaveInventoryMovementResult> {
    const res = await this.invoke('pos_db_execute', {
      op: {
        type: 'SaveInventoryMovement',
        payload: {
          id: input.id || null,
          product_id: input.productId,
          movement_type: input.movementType,
          quantity_change: input.quantityChange,
          created_by_staff_id: input.createdByStaffId || null,
          reference_movement_id: input.referenceMovementId || null,
          created_at: input.createdAt || null,
        },
      },
    });

    this.notifyCommittedWrite('inventory_movements');

    return {
      movementId: res.movement_id,
      productId: res.product_id,
      newStock: res.new_stock,
      outboxEntry: res.outbox_entry,
    };
  }

  // --- 9, 10, 11: Outbox Queue ---

  public async getPendingOutbox(limit: number = 10): Promise<OutboxRow[]> {
    const res = await this.invoke('pos_db_query', {
      query: {
        type: 'GetPendingOutbox',
        payload: { limit },
      },
    });
    return (res || []) as OutboxRow[];
  }

  public async acknowledgeOutbox(seq: number): Promise<void> {
    await this.invoke('pos_db_execute', {
      op: {
        type: 'AcknowledgeOutbox',
        payload: { seq },
      },
    });
  }

  public async updateOutboxFailure(seq: number, error: string, nextAttemptAt?: string | null): Promise<void> {
    await this.invoke('pos_db_execute', {
      op: {
        type: 'UpdateOutboxFailure',
        payload: {
          seq,
          error,
          next_attempt_at: nextAttemptAt || null,
        },
      },
    });
  }

  // --- 12 & 13: Sync Cursor & Pull Batch Application ---

  public async getSyncCursor(dataset: PullDataset): Promise<SyncCursor> {
    const res = await this.invoke('pos_db_query', {
      query: {
        type: 'GetSyncCursor',
        payload: { dataset },
      },
    });
    return {
      dataset: res.dataset,
      lastUpdatedAt: res.last_updated_at,
      lastId: res.last_id,
      updatedAt: res.updated_at,
    };
  }

  public async applyPullBatch(
    dataset: PullDataset,
    rows: unknown[],
    newCursor: { lastUpdatedAt: string; lastId: string }
  ): Promise<number> {
    const res = await this.invoke('pos_db_execute', {
      op: {
        type: 'ApplyPullBatch',
        payload: {
          dataset,
          rows,
          new_cursor: {
            last_updated_at: newCursor.lastUpdatedAt,
            last_id: newCursor.lastId,
          },
        },
      },
    });
    return Number(res?.rowsApplied ?? 0);
  }

  // --- 14: Tables with Sessions ---

  public async getTablesWithSessions(): Promise<TableWithActiveSession[]> {
    const res = await this.invoke('pos_db_query', {
      query: { type: 'GetTablesWithSessions' },
    });
    return (res || []) as TableWithActiveSession[];
  }

  // --- 15: Catalog ---

  public async getCatalog(): Promise<PosCatalog> {
    const res = await this.invoke('pos_db_query', {
      query: { type: 'GetCatalog' },
    });
    return res as PosCatalog;
  }

  // --- 16: Active Order For Table ---

  public async getActiveOrderForTable(tableId: string): Promise<ActiveTableOrderResult | null> {
    const res = await this.invoke('pos_db_query', {
      query: {
        type: 'GetActiveOrderForTable',
        payload: { table_id: tableId },
      },
    });
    return res ? (res as ActiveTableOrderResult) : null;
  }

  // --- 17: Bill For Order ---

  public async getBillForOrder(orderId: string): Promise<LocalBill | null> {
    const res = await this.invoke('pos_db_query', {
      query: {
        type: 'GetBillForOrder',
        payload: { order_id: orderId },
      },
    });
    return res ? (res as LocalBill) : null;
  }

  // --- 18: Open Table Session ---

  public async openTableSession(tableId: string, guestCount: number): Promise<TableSessionDomain> {
    const res = await this.invoke('pos_db_execute', {
      op: {
        type: 'OpenTableSession',
        payload: {
          table_id: tableId,
          guest_count: guestCount,
        },
      },
    });

    this.notifyCommittedWrite('table_sessions');
    return res as TableSessionDomain;
  }

  // --- 19: Close Table Session ---

  public async closeTableSession(sessionId: string, orderId: string): Promise<void> {
    await this.invoke('pos_db_execute', {
      op: {
        type: 'CloseTableSession',
        payload: {
          session_id: sessionId,
          order_id: orderId,
        },
      },
    });

    this.notifyCommittedWrite('table_sessions');
    this.notifyCommittedWrite('orders');
  }

  // --- 20: KOTs with Items for Order ---

  public async getKotsForOrder(orderId: string): Promise<OrderKotHeaderWithItems[]> {
    const res = await this.invoke('pos_db_query', {
      query: {
        type: 'GetKotsForOrder',
        payload: { order_id: orderId },
      },
    });
    return (res || []) as OrderKotHeaderWithItems[];
  }
}

export type {
  TableWithActiveSession,
  PosCatalog,
  ActiveTableOrderResult,
  LocalBill,
  TableOccupancyStatus,
  OrderKotHeaderWithItems,
};

export function deriveTableOccupancy(session: TableSessionDomain | null | undefined): TableOccupancyStatus {
  if (!session) return 'AVAILABLE';
  if (session.session_status === 'open') return 'OCCUPIED';
  if (session.session_status === 'billed') return 'BILLED';
  return 'AVAILABLE';
}

/**
 * Factory function creating a production Tauri native persistence adapter instance.
 */
export function createTauriPosPersistence(invokeHandler?: TauriInvokeHandler): TauriPosPersistence {
  return new TauriPosPersistence(invokeHandler);
}

// Backward compatibility alias
export const createTauriPosDatabase = createTauriPosPersistence;
export { TauriPosPersistence as TauriPosDatabase };

export interface TauriPushTransportOptions {
  invokeHandler?: TauriInvokeHandler;
  getStaffToken: () => Promise<string | null> | string | null;
}

export interface NativeProvisionDeviceInput {
  terminalCode: string;
  deviceName: string;
  adminToken: string;
  invokeHandler?: TauriInvokeHandler;
}

export interface NativeProvisionDeviceResult {
  deviceId: string;
  terminalCode: string;
  deviceName: string;
  createdAt: string;
  success: boolean;
}

/**
 * Executes native device provisioning via Tauri IPC command.
 * Plaintext device secret is protected in DPAPI/vault by Rust and never returned to renderer.
 */
export async function nativeProvisionDevice(
  input: NativeProvisionDeviceInput
): Promise<NativeProvisionDeviceResult> {
  const invoke = input.invokeHandler || resolveTauriInvoke();
  const res = await invoke('native_provision_device', {
    terminalCode: input.terminalCode,
    deviceName: input.deviceName,
    adminToken: input.adminToken,
    terminal_code: input.terminalCode,
    device_name: input.deviceName,
    admin_token: input.adminToken,
  });
  return {
    deviceId: res.device_id,
    terminalCode: res.terminal_code,
    deviceName: res.device_name,
    createdAt: res.created_at,
    success: Boolean(res.success ?? true),
  };
}

/**
 * Creates a Production-ready CloudRpcTransport that forwards mutations through the native Rust Tauri IPC.
 * Rust unprotects device secret, injects authoritative device_id, and attaches staff JWT.
 */
export function createTauriPushTransport(
  optionsOrInvoke: TauriPushTransportOptions | TauriInvokeHandler,
  tokenProvider?: () => Promise<string | null> | string | null
): CloudRpcTransport {
  let invoke: TauriInvokeHandler;
  let getStaffToken: () => Promise<string | null> | string | null;

  if (typeof optionsOrInvoke === 'function') {
    invoke = optionsOrInvoke;
    getStaffToken = tokenProvider || (() => null);
  } else {
    invoke = optionsOrInvoke.invokeHandler || resolveTauriInvoke();
    getStaffToken = optionsOrInvoke.getStaffToken;
  }

  const dispatchNativeRpc = async (
    op: 'order' | 'kot' | 'kot_correction' | 'bill' | 'payment' | 'inventory_movement' | 'table_session' | 'replace_draft_order' | 'append_order_items_and_kot',
    payload: Record<string, unknown>
  ): Promise<boolean> => {
    const staffToken = await getStaffToken();
    if (!staffToken || !staffToken.trim()) {
      throw new PushSyncError('AUTH_REQUIRED', 'STAFF_TOKEN_MISSING: Short-lived staff access token required for cloud mutation');
    }

    let res: any;
    try {
      res = await invoke('native_pos_rpc', {
        req: {
          op,
          payload,
          staff_token: staffToken,
        },
      });
    } catch (err: any) {
      const msg = typeof err === 'string' ? err : err?.message || String(err);
      const code = err?.code || '';

      if (
        code === 'DEVICE_REVOKED' ||
        code === 'DEVICE_AUTH_FAILED' ||
        code === 'AUTH_REQUIRED' ||
        msg.includes('DEVICE_REVOKED') ||
        msg.includes('DEVICE_AUTH_FAILED') ||
        msg.includes('AUTH_REQUIRED') ||
        msg.includes('DEVICE_NOT_PROVISIONED') ||
        msg.includes('Access Denied') ||
        msg.includes('42501')
      ) {
        throw new PushSyncError('AUTH_REQUIRED', msg, err);
      }
      if (
        code === 'CONTRACT_CONFLICT' ||
        msg.includes('CONTRACT_CONFLICT') ||
        msg.includes('DEVICE_MISMATCH') ||
        msg.includes('Overpayment Denied') ||
        msg.includes('Restoration Over-Credit Denied') ||
        msg.includes('Insufficient stock')
      ) {
        throw new PushSyncError('CONTRACT_CONFLICT', msg, err);
      }
      throw new PushSyncError('RETRYABLE', msg, err);
    }

    if (res && res.success === false) {
      const errorClass = res.error_class || '';
      const errorMsg = res.error_message || 'Native RPC execution failed';
      if (
        errorClass === 'DEVICE_REVOKED' ||
        errorClass === 'DEVICE_AUTH_FAILED' ||
        errorClass === 'AUTH_REQUIRED'
      ) {
        throw new PushSyncError('AUTH_REQUIRED', errorMsg, res);
      }
      if (errorClass === 'CONTRACT_CONFLICT') {
        throw new PushSyncError('CONTRACT_CONFLICT', errorMsg, res);
      }
      throw new PushSyncError('RETRYABLE', errorMsg, res);
    }

    return res?.data ?? true;
  };

  return {
    async syncTableSession(session) {
      return await dispatchNativeRpc('table_session', { session });
    },
    async syncOrder(order, items) {
      return await dispatchNativeRpc('order', { order, items });
    },
    async replaceDraftOrder(order, items) {
      return await dispatchNativeRpc('replace_draft_order', { order, items });
    },
    async syncKot(kot, items) {
      return await dispatchNativeRpc('kot', { kot, items });
    },
    async syncKotCorrection(correction, updatedOrderItem, updatedOrder) {
      return await dispatchNativeRpc('kot_correction', {
        correction,
        updatedOrderItem,
        updatedOrder,
      });
    },
    async syncBill(bill) {
      return await dispatchNativeRpc('bill', { bill });
    },
    async syncPayment(payment) {
      return await dispatchNativeRpc('payment', { payment });
    },
    async applyInventoryMovement(input) {
      return await dispatchNativeRpc('inventory_movement', input as Record<string, unknown>);
    },
    async appendOrderItemsAndKot(order, newOrderItems, kot, kotItems) {
      return await dispatchNativeRpc('append_order_items_and_kot', {
        order,
        orderItems: newOrderItems,
        kot,
        items: kotItems,
      });
    },
  };
}
