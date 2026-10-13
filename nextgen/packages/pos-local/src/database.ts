/**
 * CHEESYOS NEXTGEN POS LOCAL — DATABASE MANAGER
 * 
 * Manages SQLite database connection lifecycle, WAL mode, foreign keys, and schema initialization.
 */

import { DatabaseSync } from 'node:sqlite';
import {
  OrderDomain,
  OrderItemDomain,
  PosKotDomain,
  KotItemDomain,
  KotCorrectionDomain,
  BillDomain,
  PaymentDomain,
  PosTableDomain,
  TableSessionDomain,
} from '@cheesyos/nextgen-shared';
import { INITIAL_SCHEMA_SQL, SCHEMA_VERSION } from './schema.js';
import { IPosLocalDatabase, ISQLiteDatabase } from './adapter.js';
import {
  IPosPersistence,
  PullDataset,
  LocalDeviceConfigInput,
  TableWithActiveSession,
  PosCatalog,
  ActiveTableOrderResult,
  LocalBill,
  LocalOrderHeader,
  LocalOrderItem,
  OrderKotHeaderWithItems,
} from './persistence.js';
import { LocalDeviceConfig, getDeviceConfig, setLocalDeviceConfig } from './device.js';
import {
  OutboxRow,
  SyncCursor,
  getPendingOutboxEntries,
  acknowledgeOutboxRecord,
  updateOutboxRecordFailure,
  getSyncCursor,
} from './outbox.js';
import {
  SaveOrderResult,
  SaveKotResult,
  AppendOrderItemsAndKotResult,
  SaveBillWithSequenceResult,
  SavePaymentResult,
  SaveInventoryMovementInput,
  SaveInventoryMovementResult,
  saveOrderTransaction,
  replaceDraftOrderAggregateTransaction,
  saveKotDispatchTransaction,
  saveKotCorrectionTransaction,
  applyKotCorrectionTransaction,
  ApplyKotCorrectionInput,
  ApplyKotCorrectionLocalResult,
  appendOrderItemsAndKotTransaction,
  saveBillWithSequenceTransaction,
  savePaymentTransaction,
  saveInventoryMovementTransaction,
  openTableSessionTransaction,
  closeTableSessionTransaction,
} from './transactions.js';
import { applyPullBatchLocal } from './pull-batch.js';

export class PosLocalDatabase implements IPosLocalDatabase, IPosPersistence {
  private db: DatabaseSync;
  private dbPath: string;
  private isTransactionActive: boolean = false;

  constructor(dbPath: string = ':memory:') {
    this.dbPath = dbPath;
    this.db = new DatabaseSync(dbPath);
    this.initialize();
  }

  public getRawDb(): ISQLiteDatabase {
    return this.db;
  }

  public getPath(): string {
    return this.dbPath;
  }

  public close(): void {
    this.db.close();
  }

  public getSchemaVersion(): number {
    const result = this.db.prepare('PRAGMA user_version').get() as { user_version: number } | undefined;
    return result?.user_version ?? 0;
  }

  private initialize(): void {
    // 1. Enable WAL mode (for file-based DBs) and Foreign Keys
    if (this.dbPath !== ':memory:') {
      this.db.exec('PRAGMA journal_mode = WAL;');
    }
    this.db.exec('PRAGMA foreign_keys = ON;');

    // 2. Check schema version
    const currentVersion = this.getSchemaVersion();
    if (currentVersion === 0) {
      this.db.exec(INITIAL_SCHEMA_SQL);
      this.db.exec(`PRAGMA user_version = ${SCHEMA_VERSION};`);
    } else if (currentVersion < SCHEMA_VERSION) {
      this.migrate(currentVersion, SCHEMA_VERSION);
    } else if (currentVersion > SCHEMA_VERSION) {
      throw new Error(
        `[PosLocalDatabase] Cannot open database with newer schema version (${currentVersion}) than current application supported version (${SCHEMA_VERSION})`
      );
    }
  }

  private migrate(fromVersion: number, toVersion: number): void {
    if (fromVersion < 2) {
      this.db.exec(`
        CREATE TABLE IF NOT EXISTS pos_device_config (
          device_id TEXT PRIMARY KEY,
          terminal_code TEXT NOT NULL UNIQUE,
          device_name TEXT NOT NULL,
          created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS pos_sequences (
          sequence_name TEXT PRIMARY KEY,
          current_value INTEGER NOT NULL DEFAULT 0,
          updated_at TEXT NOT NULL
        );

        PRAGMA user_version = 2;
      `);
    }
    if (fromVersion < 3) {
      const hasOrders = this.db.prepare("SELECT count(*) as count FROM sqlite_master WHERE type='table' AND name='orders'").get() as { count: number } | undefined;
      if (hasOrders && hasOrders.count > 0) {
        const hasVersionCol = this.db.prepare("SELECT count(*) as count FROM pragma_table_info('orders') WHERE name='version'").get() as { count: number } | undefined;
        if (!hasVersionCol || hasVersionCol.count === 0) {
          this.db.exec(`ALTER TABLE orders ADD COLUMN version INTEGER NOT NULL DEFAULT 1;`);
        }
      }
      this.db.exec(`PRAGMA user_version = 3;`);
    }
    if (fromVersion < 4) {
      // 1. Rebuild order_items table to relax CHECK (quantity > 0) to CHECK (quantity >= 0)
      const hasOrderItems = this.db.prepare("SELECT count(*) as count FROM sqlite_master WHERE type='table' AND name='order_items'").get() as { count: number } | undefined;
      if (hasOrderItems && hasOrderItems.count > 0) {
        const hasNotes = this.db.prepare("SELECT count(*) as count FROM pragma_table_info('order_items') WHERE name='notes'").get() as { count: number } | undefined;
        const notesSelect = (hasNotes && hasNotes.count > 0) ? 'notes' : 'NULL as notes';
        this.db.exec(`
          PRAGMA foreign_keys = OFF;
          CREATE TABLE order_items_v4 (
            id TEXT PRIMARY KEY,
            order_id TEXT NOT NULL,
            product_id TEXT NOT NULL,
            variant_id TEXT,
            product_name TEXT NOT NULL,
            unit_price_paise INTEGER NOT NULL CHECK (unit_price_paise >= 0),
            quantity INTEGER NOT NULL CHECK (quantity >= 0),
            tax_rate REAL DEFAULT 5.00 CHECK (tax_rate >= 0),
            discount_amount_paise INTEGER DEFAULT 0 CHECK (discount_amount_paise >= 0),
            line_total_paise INTEGER NOT NULL CHECK (line_total_paise >= 0),
            notes TEXT,
            created_at TEXT NOT NULL,
            FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE,
            FOREIGN KEY (product_id) REFERENCES products(id),
            FOREIGN KEY (variant_id) REFERENCES product_variants(id)
          );
          INSERT INTO order_items_v4 (id, order_id, product_id, variant_id, product_name, unit_price_paise, quantity, tax_rate, discount_amount_paise, line_total_paise, notes, created_at)
            SELECT id, order_id, product_id, variant_id, product_name, unit_price_paise, quantity, tax_rate, discount_amount_paise, line_total_paise, ${notesSelect}, created_at FROM order_items;
          DROP TABLE order_items;
          ALTER TABLE order_items_v4 RENAME TO order_items;
          PRAGMA foreign_keys = ON;
        `);
      }

      // 2. Add order_item_id to kot_items if missing
      const hasKotItems = this.db.prepare("SELECT count(*) as count FROM sqlite_master WHERE type='table' AND name='kot_items'").get() as { count: number } | undefined;
      if (hasKotItems && hasKotItems.count > 0) {
        const hasOrderItemId = this.db.prepare("SELECT count(*) as count FROM pragma_table_info('kot_items') WHERE name='order_item_id'").get() as { count: number } | undefined;
        if (!hasOrderItemId || hasOrderItemId.count === 0) {
          this.db.exec(`ALTER TABLE kot_items ADD COLUMN order_item_id TEXT REFERENCES order_items(id);`);
        }
      }

      // 3. Add kot_item_id and order_item_id to kot_corrections if missing
      const hasCorrections = this.db.prepare("SELECT count(*) as count FROM sqlite_master WHERE type='table' AND name='kot_corrections'").get() as { count: number } | undefined;
      if (hasCorrections && hasCorrections.count > 0) {
        const hasKotItemId = this.db.prepare("SELECT count(*) as count FROM pragma_table_info('kot_corrections') WHERE name='kot_item_id'").get() as { count: number } | undefined;
        if (!hasKotItemId || hasKotItemId.count === 0) {
          this.db.exec(`ALTER TABLE kot_corrections ADD COLUMN kot_item_id TEXT REFERENCES kot_items(id);`);
        }
        const hasCorrOrderItemId = this.db.prepare("SELECT count(*) as count FROM pragma_table_info('kot_corrections') WHERE name='order_item_id'").get() as { count: number } | undefined;
        if (!hasCorrOrderItemId || hasCorrOrderItemId.count === 0) {
          this.db.exec(`ALTER TABLE kot_corrections ADD COLUMN order_item_id TEXT REFERENCES order_items(id);`);
        }
      }

      this.db.exec(`PRAGMA user_version = 4;`);
    }
  }


  /**
   * Helper to execute a callback within a synchronous SQLite transaction.
   * Rejects nested transactions to prevent partial commit bugs.
   * Automatically issues COMMIT on success or ROLLBACK on exception.
   */
  public runTransaction<T>(fn: (db: ISQLiteDatabase) => T): T {
    if (this.isTransactionActive) {
      throw new Error('[PosLocalDatabase] Nested transactions are not supported. Wrap all atomic operations in a single top-level runTransaction block.');
    }

    this.isTransactionActive = true;
    this.db.exec('BEGIN IMMEDIATE;');
    try {
      const result = fn(this.db);
      this.db.exec('COMMIT;');
      this.isTransactionActive = false;
      return result;
    } catch (error) {
      try {
        this.db.exec('ROLLBACK;');
      } catch {
        // Ignore rollback failure if transaction was already aborted by SQLite
      }
      this.isTransactionActive = false;
      throw error;
    }
  }

  // --- IPosPersistence Implementation ---

  public async getDeviceConfig(): Promise<LocalDeviceConfig | null> {
    return getDeviceConfig(this.db);
  }

  public async setDeviceConfig(config: LocalDeviceConfigInput): Promise<LocalDeviceConfig> {
    return setLocalDeviceConfig(this.db, config);
  }

  public async saveOrderAggregate(order: OrderDomain, items: OrderItemDomain[]): Promise<SaveOrderResult> {
    return saveOrderTransaction(this, order, items);
  }

  public async replaceDraftOrderAggregate(order: OrderDomain, items: OrderItemDomain[]): Promise<SaveOrderResult> {
    return replaceDraftOrderAggregateTransaction(this, order, items);
  }

  public async saveKotAggregate(kot: PosKotDomain, items: KotItemDomain[]): Promise<SaveKotResult> {
    return saveKotDispatchTransaction(this, kot, items);
  }

  public async saveKotCorrection(correction: KotCorrectionDomain): Promise<OutboxRow> {
    return saveKotCorrectionTransaction(this, correction);
  }

  public async applyKotCorrection(input: ApplyKotCorrectionInput): Promise<ApplyKotCorrectionLocalResult> {
    return applyKotCorrectionTransaction(this, input);
  }

  public async appendOrderItemsAndKot(
    order: OrderDomain,
    newItems: OrderItemDomain[],
    kot: PosKotDomain,
    kotItems: KotItemDomain[]
  ): Promise<AppendOrderItemsAndKotResult> {
    return appendOrderItemsAndKotTransaction(this, order, newItems, kot, kotItems);
  }

  public async saveBillWithSequence(bill: BillDomain): Promise<SaveBillWithSequenceResult> {
    return saveBillWithSequenceTransaction(this, bill);
  }

  public async savePayment(payment: PaymentDomain, updatedBill: BillDomain): Promise<SavePaymentResult> {
    return savePaymentTransaction(this, payment, updatedBill);
  }

  public async saveInventoryMovement(input: SaveInventoryMovementInput): Promise<SaveInventoryMovementResult> {
    return saveInventoryMovementTransaction(this, input);
  }

  public async getPendingOutbox(limit: number = 10): Promise<OutboxRow[]> {
    return getPendingOutboxEntries(this.db, limit);
  }

  public async acknowledgeOutbox(seq: number): Promise<void> {
    this.runTransaction((db) => {
      acknowledgeOutboxRecord(db, seq);
    });
  }

  public async updateOutboxFailure(seq: number, error: string, nextAttemptAt?: string | null): Promise<void> {
    this.runTransaction((db) => {
      updateOutboxRecordFailure(db, seq, error, nextAttemptAt ?? null);
    });
  }

  public async getSyncCursor(dataset: PullDataset): Promise<SyncCursor> {
    return getSyncCursor(this.db, dataset);
  }

  public async applyPullBatch(
    dataset: PullDataset,
    rows: unknown[],
    newCursor: { lastUpdatedAt: string; lastId: string }
  ): Promise<number> {
    return this.runTransaction((db) => {
      return applyPullBatchLocal(db, dataset, rows as any[], newCursor);
    });
  }

  public async getTablesWithSessions(): Promise<TableWithActiveSession[]> {
    const tableRows = this.db.prepare(`
      SELECT id, table_number, section, capacity, is_active, created_at
      FROM pos_tables
      WHERE is_active = 1
      ORDER BY section ASC, table_number ASC
    `).all() as any[];

    const sessionRows = this.db.prepare(`
      SELECT id, table_id, current_order_id, guest_count, session_status, opened_at, closed_at
      FROM table_sessions
      WHERE session_status IN ('open', 'billed')
      ORDER BY opened_at DESC
    `).all() as any[];

    const sessionMap = new Map<string, TableSessionDomain[]>();
    for (const s of sessionRows) {
      const session: TableSessionDomain = {
        id: s.id,
        table_id: s.table_id,
        current_order_id: s.current_order_id || null,
        guest_count: s.guest_count,
        session_status: s.session_status,
        opened_at: s.opened_at,
        closed_at: s.closed_at || null,
      };
      const list = sessionMap.get(s.table_id) || [];
      list.push(session);
      sessionMap.set(s.table_id, list);
    }

    const result: TableWithActiveSession[] = [];
    for (const t of tableRows) {
      const sessions = sessionMap.get(t.id);
      if (sessions && sessions.length > 1) {
        throw new Error(`INVARIANT_VIOLATION: Multiple active sessions (${sessions.length}) found for table ${t.id}`);
      }
      const active_session = sessions && sessions.length === 1 ? sessions[0] : null;

      result.push({
        table: {
          id: t.id,
          table_number: t.table_number,
          section: t.section,
          capacity: t.capacity,
          is_active: Boolean(t.is_active),
          created_at: t.created_at,
        },
        active_session,
      });
    }

    return result;
  }

  public async getCatalog(): Promise<PosCatalog> {
    const categories = (this.db.prepare(`
      SELECT id, name, slug, display_order, is_active, created_at, updated_at
      FROM categories
      WHERE is_active = 1
      ORDER BY display_order ASC, name ASC
    `).all() as any[]).map((c) => ({
      id: c.id,
      name: c.name,
      slug: c.slug,
      display_order: c.display_order,
      is_active: Boolean(c.is_active),
      created_at: c.created_at,
      updated_at: c.updated_at,
    }));

    const products = (this.db.prepare(`
      SELECT p.id, p.category_id, p.name, p.description, p.image_url,
             p.base_price_paise, p.is_available, p.tax_rate, p.is_inventory_tracked,
             p.created_at, p.updated_at
      FROM products p
      INNER JOIN categories c ON p.category_id = c.id
      WHERE c.is_active = 1 AND p.is_available = 1
      ORDER BY c.display_order ASC, p.name ASC
    `).all() as any[]).map((p) => ({
      id: p.id,
      category_id: p.category_id,
      name: p.name,
      description: p.description ?? null,
      image_url: p.image_url ?? null,
      base_price_paise: p.base_price_paise,
      is_available: Boolean(p.is_available),
      tax_rate: p.tax_rate,
      is_inventory_tracked: Boolean(p.is_inventory_tracked),
      created_at: p.created_at,
      updated_at: p.updated_at,
    }));

    const variants = (this.db.prepare(`
      SELECT pv.id, pv.product_id, pv.variant_name, pv.price_override_paise,
             pv.is_available, pv.created_at
      FROM product_variants pv
      INNER JOIN products p ON pv.product_id = p.id
      INNER JOIN categories c ON p.category_id = c.id
      WHERE c.is_active = 1 AND p.is_available = 1 AND pv.is_available = 1
      ORDER BY pv.variant_name ASC
    `).all() as any[]).map((v) => ({
      id: v.id,
      product_id: v.product_id,
      variant_name: v.variant_name,
      price_override_paise: v.price_override_paise ?? null,
      is_available: Boolean(v.is_available),
      created_at: v.created_at,
    }));

    return { categories, products, variants };
  }

  public async getActiveOrderForTable(tableId: string): Promise<ActiveTableOrderResult | null> {
    const sessionRows = this.db.prepare(`
      SELECT id, table_id, current_order_id, guest_count, session_status, opened_at, closed_at
      FROM table_sessions
      WHERE table_id = ? AND session_status IN ('open', 'billed')
      ORDER BY opened_at DESC
    `).all(tableId) as any[];

    if (sessionRows.length === 0) {
      return null;
    }
    if (sessionRows.length > 1) {
      throw new Error(`INVARIANT_VIOLATION: Multiple active sessions (${sessionRows.length}) found for table ${tableId}`);
    }

    const s = sessionRows[0];
    const session: TableSessionDomain = {
      id: s.id,
      table_id: s.table_id,
      current_order_id: s.current_order_id || null,
      guest_count: s.guest_count,
      session_status: s.session_status,
      opened_at: s.opened_at,
      closed_at: s.closed_at || null,
    };

    const orderRows = this.db.prepare(`
      SELECT id, display_number, channel, order_type, customer_id, table_session_id,
             status, subtotal_paise, tax_total_paise, discount_total_paise,
             delivery_charge_paise, grand_total_paise, device_id, version, created_at, updated_at
      FROM orders
      WHERE (table_session_id = ? OR (id = ? AND ? IS NOT NULL AND ? != ''))
        AND status NOT IN ('cancelled', 'closed')
      ORDER BY created_at DESC
    `).all(session.id, session.current_order_id || '', session.current_order_id || '', session.current_order_id || '') as any[];

    if (orderRows.length === 0) {
      return null;
    }
    if (orderRows.length > 1) {
      throw new Error(`INVARIANT_VIOLATION: Multiple active orders (${orderRows.length}) found for table session ${session.id}`);
    }

    const o = orderRows[0];
    const order: LocalOrderHeader = {
      id: o.id,
      display_number: o.display_number ?? null,
      channel: o.channel,
      order_type: o.order_type,
      customer_id: o.customer_id ?? null,
      table_session_id: o.table_session_id ?? null,
      status: o.status,
      subtotal_paise: o.subtotal_paise,
      tax_total_paise: o.tax_total_paise,
      discount_total_paise: o.discount_total_paise,
      delivery_charge_paise: o.delivery_charge_paise,
      grand_total_paise: o.grand_total_paise,
      device_id: o.device_id ?? null,
      version: o.version ?? 1,
      created_at: o.created_at,
      updated_at: o.updated_at,
    };

    const itemRows = this.db.prepare(`
      SELECT id, order_id, product_id, variant_id, product_name,
             unit_price_paise, quantity, tax_rate, discount_amount_paise,
             line_total_paise, notes, created_at
      FROM order_items
      WHERE order_id = ?
      ORDER BY created_at ASC, id ASC
    `).all(order.id) as any[];

    const items: LocalOrderItem[] = itemRows.map((item) => ({
      id: item.id,
      order_id: item.order_id,
      product_id: item.product_id,
      variant_id: item.variant_id ?? null,
      product_name: item.product_name,
      unit_price_paise: item.unit_price_paise,
      quantity: item.quantity,
      tax_rate: item.tax_rate,
      discount_amount_paise: item.discount_amount_paise,
      line_total_paise: item.line_total_paise,
      notes: item.notes ?? null,
      created_at: item.created_at,
    }));

    return { session, order, items };
  }

  public async getBillForOrder(orderId: string): Promise<LocalBill | null> {
    const row = this.db.prepare(`
      SELECT id, order_id, bill_number, subtotal_paise, cgst_total_paise,
             sgst_total_paise, discount_total_paise, grand_total_paise,
             payment_status, finalized_at, device_id
      FROM bills
      WHERE order_id = ?
    `).get(orderId) as any | undefined;

    if (!row) {
      return null;
    }

    return {
      id: row.id,
      order_id: row.order_id,
      bill_number: row.bill_number,
      subtotal_paise: row.subtotal_paise,
      cgst_total_paise: row.cgst_total_paise,
      sgst_total_paise: row.sgst_total_paise,
      discount_total_paise: row.discount_total_paise,
      grand_total_paise: row.grand_total_paise,
      payment_status: row.payment_status,
      finalized_at: row.finalized_at,
      device_id: row.device_id ?? null,
    };
  }

  public async openTableSession(tableId: string, guestCount: number): Promise<TableSessionDomain> {
    return openTableSessionTransaction(this, tableId, guestCount);
  }

  public async closeTableSession(sessionId: string, orderId: string): Promise<void> {
    return closeTableSessionTransaction(this, sessionId, orderId);
  }

  public async getKotsForOrder(orderId: string): Promise<OrderKotHeaderWithItems[]> {
    const kotRows = this.db.prepare(`
      SELECT id, order_id, kot_number, device_id, status, printed_at
      FROM pos_kots
      WHERE order_id = ?
      ORDER BY kot_number ASC, id ASC
    `).all(orderId) as any[];

    if (!kotRows || kotRows.length === 0) {
      return [];
    }

    const itemStmt = this.db.prepare(`
      SELECT id, kot_id, order_item_id, product_id, variant_id, product_name, quantity, notes
      FROM kot_items
      WHERE kot_id = ?
      ORDER BY id ASC
    `);

    return kotRows.map((k) => {
      const items = itemStmt.all(k.id) as any[];
      return {
        kot: {
          id: k.id,
          order_id: k.order_id,
          kot_number: k.kot_number,
          device_id: k.device_id ?? null,
          status: k.status,
          printed_at: k.printed_at,
        },
        items: items.map((it) => ({
          id: it.id,
          kot_id: it.kot_id,
          order_item_id: it.order_item_id ?? null,
          product_id: it.product_id,
          variant_id: it.variant_id ?? null,
          product_name: it.product_name,
          quantity: it.quantity,
          notes: it.notes ?? null,
        })),
      };
    });
  }
}
