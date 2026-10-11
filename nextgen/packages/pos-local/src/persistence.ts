/**
 * CHEESYOS NEXTGEN POS LOCAL — ASYNCHRONOUS SEMANTIC PERSISTENCE CONTRACT
 * 
 * Defines the single primary persistence contract for CheesyOS POS.
 * All methods are asynchronous (Promise-based) to provide a unified interface for:
 * 1. Node.js native SQLite (for automated unit/integration tests & server tooling)
 * 2. Future Windows Desktop native persistence (via narrow Tauri IPC -> Rust rusqlite)
 * 
 * SECURITY INVARIANT:
 * Zero raw SQL strings cross this boundary. All operations are semantic domain aggregates.
 */

import type {
  OrderDomain,
  OrderItemDomain,
  PosKotDomain,
  KotItemDomain,
  KotCorrectionDomain,
  BillDomain,
  PaymentDomain,
} from '@cheesyos/nextgen-shared';
import type { LocalDeviceConfig } from './device.js';
import type { OutboxRow, SyncCursor } from './outbox.js';
import type {
  SaveOrderResult,
  SaveKotResult,
  SaveBillResult,
  SaveBillWithSequenceResult,
  SavePaymentResult,
  SaveInventoryMovementInput,
  SaveInventoryMovementResult,
} from './transactions.js';

export type { SaveBillWithSequenceResult };

export type PullDataset =
  | 'categories'
  | 'products'
  | 'product_variants'
  | 'customers'
  | 'pos_tables'
  | 'table_sessions'
  | 'orders'
  | 'order_items'
  | 'pos_kots'
  | 'kot_items'
  | 'kot_corrections'
  | 'bills'
  | 'payments'
  | 'inventory_lite';

export interface LocalDeviceConfigInput {
  device_id: string;
  terminal_code: string;
  device_name: string;
  created_at?: string;
}

export interface IPosPersistence {
  // 1 & 2: Device Config
  getDeviceConfig(): Promise<LocalDeviceConfig | null>;
  setDeviceConfig(config: LocalDeviceConfigInput): Promise<LocalDeviceConfig>;

  // 3: Order Aggregate
  saveOrderAggregate(order: OrderDomain, items: OrderItemDomain[]): Promise<SaveOrderResult>;

  // 4 & 5: KOT Aggregate & Correction
  saveKotAggregate(kot: PosKotDomain, items: KotItemDomain[]): Promise<SaveKotResult>;
  saveKotCorrection(correction: KotCorrectionDomain): Promise<OutboxRow>;

  // 6: Bill with Atomic Sequence Allocation
  saveBillWithSequence(bill: BillDomain): Promise<SaveBillWithSequenceResult>;

  // 7 & 8: Payment & Inventory Movement
  savePayment(payment: PaymentDomain, updatedBill: BillDomain): Promise<SavePaymentResult>;
  saveInventoryMovement(input: SaveInventoryMovementInput): Promise<SaveInventoryMovementResult>;

  // 9, 10, 11: Outbox Queue
  getPendingOutbox(limit?: number): Promise<OutboxRow[]>;
  acknowledgeOutbox(seq: number): Promise<void>;
  updateOutboxFailure(seq: number, error: string, nextAttemptAt?: string | null): Promise<void>;

  // 12 & 13: Sync Cursor & Pull Batch Application
  getSyncCursor(dataset: PullDataset): Promise<SyncCursor>;
  applyPullBatch(
    dataset: PullDataset,
    rows: unknown[],
    newCursor: { lastUpdatedAt: string; lastId: string }
  ): Promise<number>;
}
