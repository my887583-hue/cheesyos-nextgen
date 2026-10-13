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
  PosTableDomain,
  TableSessionDomain,
  OrderChannel,
  OrderType,
  OrderStatus,
  PaymentStatus,
} from '@cheesyos/nextgen-shared';
import type { LocalDeviceConfig } from './device.js';
import type { OutboxRow, SyncCursor } from './outbox.js';
import type {
  SaveOrderResult,
  SaveKotResult,
  AppendOrderItemsAndKotResult,
  SaveBillResult,
  SaveBillWithSequenceResult,
  SavePaymentResult,
  SaveInventoryMovementInput,
  SaveInventoryMovementResult,
  ApplyKotCorrectionInput,
  ApplyKotCorrectionLocalResult,
} from './transactions.js';

export type { SaveBillWithSequenceResult, AppendOrderItemsAndKotResult, ApplyKotCorrectionInput, ApplyKotCorrectionLocalResult };

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

export interface TableWithActiveSession {
  table: PosTableDomain;
  active_session: TableSessionDomain | null;
}

export type TableOccupancyStatus = 'AVAILABLE' | 'OCCUPIED' | 'BILLED';

export function deriveTableOccupancy(session: TableSessionDomain | null | undefined): TableOccupancyStatus {
  if (!session) return 'AVAILABLE';
  if (session.session_status === 'open') return 'OCCUPIED';
  if (session.session_status === 'billed') return 'BILLED';
  return 'AVAILABLE';
}

export interface CategoryCatalogDomain {
  id: string;
  name: string;
  slug: string;
  display_order: number;
  is_active: boolean;
  created_at: string;
  updated_at: string;
}

export interface ProductCatalogDomain {
  id: string;
  category_id: string;
  name: string;
  description: string | null;
  image_url: string | null;
  base_price_paise: number;
  is_available: boolean;
  tax_rate: number;
  is_inventory_tracked: boolean;
  created_at: string;
  updated_at: string;
}

export interface ProductVariantCatalogDomain {
  id: string;
  product_id: string;
  variant_name: string;
  price_override_paise: number | null;
  is_available: boolean;
  created_at: string;
}

export interface PosCatalog {
  categories: CategoryCatalogDomain[];
  products: ProductCatalogDomain[];
  variants: ProductVariantCatalogDomain[];
}

export interface LocalOrderHeader {
  id: string;
  display_number: string | null;
  channel: OrderChannel;
  order_type: OrderType;
  customer_id: string | null;
  table_session_id: string | null;
  status: OrderStatus;
  subtotal_paise: number;
  tax_total_paise: number;
  discount_total_paise: number;
  delivery_charge_paise: number;
  grand_total_paise: number;
  device_id: string | null;
  version: number;
  created_at: string;
  updated_at: string;
}

export interface LocalOrderItem {
  id: string;
  order_id: string;
  product_id: string;
  variant_id: string | null;
  product_name: string;
  unit_price_paise: number;
  quantity: number;
  tax_rate: number;
  discount_amount_paise: number;
  line_total_paise: number;
  notes: string | null;
  created_at: string;
}

export interface ActiveTableOrderResult {
  session: TableSessionDomain;
  order: LocalOrderHeader;
  items: LocalOrderItem[];
}

export interface LocalBill {
  id: string;
  order_id: string;
  bill_number: string;
  subtotal_paise: number;
  cgst_total_paise: number;
  sgst_total_paise: number;
  discount_total_paise: number;
  grand_total_paise: number;
  payment_status: PaymentStatus;
  finalized_at: string;
  device_id: string | null;
}

export type BillWithPaise = LocalBill;

export interface IPosPersistence {
  // 1 & 2: Device Config
  getDeviceConfig(): Promise<LocalDeviceConfig | null>;
  setDeviceConfig(config: LocalDeviceConfigInput): Promise<LocalDeviceConfig>;

  // 3: Order Aggregate
  saveOrderAggregate(order: OrderDomain, items: OrderItemDomain[]): Promise<SaveOrderResult>;
  replaceDraftOrderAggregate(order: OrderDomain, items: OrderItemDomain[]): Promise<SaveOrderResult>;

  // 4 & 5: KOT Aggregate & Correction
  saveKotAggregate(kot: PosKotDomain, items: KotItemDomain[]): Promise<SaveKotResult>;
  saveKotCorrection(correction: KotCorrectionDomain): Promise<OutboxRow>;
  applyKotCorrection(input: ApplyKotCorrectionInput): Promise<ApplyKotCorrectionLocalResult>;
  appendOrderItemsAndKot(
    order: OrderDomain,
    newItems: OrderItemDomain[],
    kot: PosKotDomain,
    kotItems: KotItemDomain[]
  ): Promise<AppendOrderItemsAndKotResult>;

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

  // 14: Tables with Sessions
  getTablesWithSessions(): Promise<TableWithActiveSession[]>;

  // 15: Catalog
  getCatalog(): Promise<PosCatalog>;

  // 16: Active Order For Table
  getActiveOrderForTable(tableId: string): Promise<ActiveTableOrderResult | null>;

  // 17: Bill For Order
  getBillForOrder(orderId: string): Promise<LocalBill | null>;

  // 18: Open Table Session
  openTableSession(tableId: string, guestCount: number): Promise<TableSessionDomain>;

  // 19: Close Table Session
  closeTableSession(sessionId: string, orderId: string): Promise<void>;

  // 20: KOTs with Items for Order
  getKotsForOrder(orderId: string): Promise<OrderKotHeaderWithItems[]>;
}

export interface OrderKotHeaderWithItems {
  kot: PosKotDomain;
  items: KotItemDomain[];
}
