/**
 * CHEESYOS NEXTGEN POS WINDOWS — RUST NATIVE SQLITE PERSISTENCE ENGINE
 * 
 * Provides pure native Rust SQLite execution for the Phase 3F.5E1 semantic contract.
 * Guarantees:
 * - Rust owns all executable SQL statements and transaction boundaries.
 * - Zero raw SQL strings or table names accepted from renderer IPC.
 * - Single atomic transactions for aggregates (Order, KOT, Bill+Seq, Payment, Inventory, Pull Batch).
 * - Finite dataset and operation enums matching TypeScript IPosPersistence parity.
 * - Automatic transaction rollback on conflict or forced failure.
 */

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

pub const SCHEMA_VERSION: i32 = 2;

pub const INITIAL_SCHEMA_SQL: &str = "
-- 1. CATEGORIES (Read-Only Cache for POS Menu)
CREATE TABLE IF NOT EXISTS categories (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  display_order INTEGER DEFAULT 0,
  is_active INTEGER DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- 2. PRODUCTS (Read-Only Cache for POS Catalog)
CREATE TABLE IF NOT EXISTS products (
  id TEXT PRIMARY KEY,
  category_id TEXT NOT NULL,
  name TEXT NOT NULL,
  description TEXT,
  image_url TEXT,
  base_price_paise INTEGER NOT NULL CHECK (base_price_paise >= 0),
  is_available INTEGER DEFAULT 1,
  tax_rate REAL DEFAULT 5.00 CHECK (tax_rate >= 0),
  is_inventory_tracked INTEGER DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (category_id) REFERENCES categories(id)
);

-- 3. PRODUCT VARIANTS (Read-Only Cache)
CREATE TABLE IF NOT EXISTS product_variants (
  id TEXT PRIMARY KEY,
  product_id TEXT NOT NULL,
  variant_name TEXT NOT NULL,
  price_override_paise INTEGER CHECK (price_override_paise >= 0),
  is_available INTEGER DEFAULT 1,
  created_at TEXT NOT NULL,
  FOREIGN KEY (product_id) REFERENCES products(id)
);

-- 4. CUSTOMERS (Cached Phone Lookup)
CREATE TABLE IF NOT EXISTS customers (
  id TEXT PRIMARY KEY,
  phone TEXT NOT NULL UNIQUE,
  full_name TEXT,
  email TEXT,
  is_active INTEGER DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- 5. POS TABLES (Floor Layout)
CREATE TABLE IF NOT EXISTS pos_tables (
  id TEXT PRIMARY KEY,
  table_number TEXT NOT NULL UNIQUE,
  section TEXT DEFAULT 'Main Floor',
  capacity INTEGER DEFAULT 4 CHECK (capacity > 0),
  is_active INTEGER DEFAULT 1,
  created_at TEXT NOT NULL
);

-- 6. TABLE SESSIONS (Dine-In Seating)
CREATE TABLE IF NOT EXISTS table_sessions (
  id TEXT PRIMARY KEY,
  table_id TEXT NOT NULL,
  current_order_id TEXT,
  guest_count INTEGER DEFAULT 1 CHECK (guest_count > 0),
  session_status TEXT NOT NULL DEFAULT 'open' CHECK (session_status IN ('open', 'billed', 'closed')),
  opened_at TEXT NOT NULL,
  closed_at TEXT,
  FOREIGN KEY (table_id) REFERENCES pos_tables(id)
);

-- 7. ORDERS (Offline Canonical Order Header)
CREATE TABLE IF NOT EXISTS orders (
  id TEXT PRIMARY KEY,
  display_number TEXT,
  channel TEXT NOT NULL CHECK (channel IN ('POS', 'WEBSITE')),
  order_type TEXT NOT NULL CHECK (order_type IN ('DINE_IN', 'TAKEAWAY', 'DELIVERY', 'PICKUP')),
  customer_id TEXT,
  table_session_id TEXT,
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'pending', 'kot_sent', 'billed', 'settled', 'cancelled', 'closed')),
  subtotal_paise INTEGER NOT NULL DEFAULT 0 CHECK (subtotal_paise >= 0),
  tax_total_paise INTEGER NOT NULL DEFAULT 0 CHECK (tax_total_paise >= 0),
  discount_total_paise INTEGER NOT NULL DEFAULT 0 CHECK (discount_total_paise >= 0),
  delivery_charge_paise INTEGER NOT NULL DEFAULT 0 CHECK (delivery_charge_paise >= 0),
  grand_total_paise INTEGER NOT NULL DEFAULT 0 CHECK (grand_total_paise >= 0),
  device_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (customer_id) REFERENCES customers(id),
  FOREIGN KEY (table_session_id) REFERENCES table_sessions(id)
);

-- 8. ORDER ITEMS (Line Items Snapshot)
CREATE TABLE IF NOT EXISTS order_items (
  id TEXT PRIMARY KEY,
  order_id TEXT NOT NULL,
  product_id TEXT NOT NULL,
  variant_id TEXT,
  product_name TEXT NOT NULL,
  unit_price_paise INTEGER NOT NULL CHECK (unit_price_paise >= 0),
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  tax_rate REAL DEFAULT 5.00 CHECK (tax_rate >= 0),
  discount_amount_paise INTEGER DEFAULT 0 CHECK (discount_amount_paise >= 0),
  line_total_paise INTEGER NOT NULL CHECK (line_total_paise >= 0),
  notes TEXT,
  created_at TEXT NOT NULL,
  FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE,
  FOREIGN KEY (product_id) REFERENCES products(id),
  FOREIGN KEY (variant_id) REFERENCES product_variants(id)
);

-- 9. POS KOTS (Kitchen Ticket Header)
CREATE TABLE IF NOT EXISTS pos_kots (
  id TEXT PRIMARY KEY,
  order_id TEXT NOT NULL,
  kot_number INTEGER NOT NULL,
  device_id TEXT,
  status TEXT NOT NULL DEFAULT 'printed' CHECK (status IN ('printed', 'cancelled')),
  printed_at TEXT NOT NULL,
  FOREIGN KEY (order_id) REFERENCES orders(id)
);

-- 10. KOT ITEMS (Dispatched Line Items)
CREATE TABLE IF NOT EXISTS kot_items (
  id TEXT PRIMARY KEY,
  kot_id TEXT NOT NULL,
  product_id TEXT NOT NULL,
  variant_id TEXT,
  product_name TEXT NOT NULL,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  notes TEXT,
  FOREIGN KEY (kot_id) REFERENCES pos_kots(id) ON DELETE CASCADE,
  FOREIGN KEY (product_id) REFERENCES products(id),
  FOREIGN KEY (variant_id) REFERENCES product_variants(id)
);

-- 11. KOT CORRECTIONS (Void Audit Log)
CREATE TABLE IF NOT EXISTS kot_corrections (
  id TEXT PRIMARY KEY,
  order_id TEXT NOT NULL,
  kot_id TEXT,
  product_name TEXT NOT NULL,
  cancelled_qty INTEGER NOT NULL CHECK (cancelled_qty > 0),
  reason TEXT NOT NULL,
  authorized_by_staff_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  FOREIGN KEY (order_id) REFERENCES orders(id),
  FOREIGN KEY (kot_id) REFERENCES pos_kots(id)
);

-- 12. BILLS (Fiscal Invoice Summary)
CREATE TABLE IF NOT EXISTS bills (
  id TEXT PRIMARY KEY,
  order_id TEXT NOT NULL UNIQUE,
  bill_number TEXT NOT NULL UNIQUE,
  subtotal_paise INTEGER NOT NULL CHECK (subtotal_paise >= 0),
  cgst_total_paise INTEGER NOT NULL CHECK (cgst_total_paise >= 0),
  sgst_total_paise INTEGER NOT NULL CHECK (sgst_total_paise >= 0),
  discount_total_paise INTEGER DEFAULT 0 CHECK (discount_total_paise >= 0),
  grand_total_paise INTEGER NOT NULL CHECK (grand_total_paise >= 0),
  payment_status TEXT NOT NULL DEFAULT 'unpaid' CHECK (payment_status IN ('unpaid', 'paid', 'partially_paid', 'refunded')),
  finalized_at TEXT NOT NULL,
  device_id TEXT,
  FOREIGN KEY (order_id) REFERENCES orders(id)
);

-- 13. PAYMENTS (Cashier Settlement Records)
CREATE TABLE IF NOT EXISTS payments (
  id TEXT PRIMARY KEY,
  bill_id TEXT NOT NULL,
  order_id TEXT NOT NULL,
  payment_mode TEXT NOT NULL CHECK (payment_mode IN ('CASH', 'UPI', 'CARD', 'OTHER')),
  amount_paid_paise INTEGER NOT NULL CHECK (amount_paid_paise > 0),
  confirmed_by_staff_id TEXT,
  confirmed_at TEXT NOT NULL,
  notes TEXT,
  FOREIGN KEY (bill_id) REFERENCES bills(id),
  FOREIGN KEY (order_id) REFERENCES orders(id)
);

-- 14. INVENTORY LITE (Ready Stock Count)
CREATE TABLE IF NOT EXISTS inventory_lite (
  id TEXT PRIMARY KEY,
  product_id TEXT NOT NULL UNIQUE,
  current_stock INTEGER NOT NULL DEFAULT 0,
  low_stock_threshold INTEGER DEFAULT 5,
  is_tracked INTEGER DEFAULT 1,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (product_id) REFERENCES products(id)
);

-- 15. INVENTORY MOVEMENTS (Stock Audit Log)
CREATE TABLE IF NOT EXISTS inventory_movements (
  id TEXT PRIMARY KEY,
  product_id TEXT NOT NULL,
  movement_type TEXT NOT NULL CHECK (movement_type IN ('SALE', 'CANCEL_RESTORE', 'MANUAL_ADD', 'MANUAL_REMOVE', 'ADJUSTMENT')),
  quantity_change INTEGER NOT NULL,
  created_by TEXT,
  reference_movement_id TEXT,
  created_at TEXT NOT NULL,
  FOREIGN KEY (product_id) REFERENCES products(id),
  FOREIGN KEY (reference_movement_id) REFERENCES inventory_movements(id)
);

-- 16. SYNC OUTBOX (Durable Cloud Sync Queue)
CREATE TABLE IF NOT EXISTS sync_outbox (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  operation TEXT NOT NULL CHECK (operation IN ('INSERT', 'UPDATE')),
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TEXT,
  last_error TEXT
);

-- 17. SYNC CURSORS (Persisted Cloud Pull Watermarks)
CREATE TABLE IF NOT EXISTS sync_cursors (
  dataset TEXT PRIMARY KEY,
  last_updated_at TEXT NOT NULL,
  last_id TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- 18. POS DEVICE CONFIG (Durable Local Terminal Identity)
CREATE TABLE IF NOT EXISTS pos_device_config (
  device_id TEXT PRIMARY KEY,
  terminal_code TEXT NOT NULL UNIQUE,
  device_name TEXT NOT NULL,
  created_at TEXT NOT NULL
);

-- 19. POS SEQUENCES (Durable Local Sequence Counters)
CREATE TABLE IF NOT EXISTS pos_sequences (
  sequence_name TEXT PRIMARY KEY,
  current_value INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);
";

// --- Domain Models ---

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct DeviceConfig {
    pub device_id: String,
    pub terminal_code: String,
    pub device_name: String,
    pub created_at: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct SetDeviceConfigInput {
    pub device_id: String,
    pub terminal_code: String,
    pub device_name: String,
    pub created_at: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct OrderDomain {
    pub id: String,
    pub display_number: Option<String>,
    pub channel: String,
    pub order_type: String,
    pub customer_id: Option<String>,
    pub table_session_id: Option<String>,
    pub status: String,
    pub subtotal_paise: i64,
    pub tax_total_paise: i64,
    pub discount_total_paise: i64,
    pub delivery_charge_paise: i64,
    pub grand_total_paise: i64,
    pub device_id: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct OrderItemDomain {
    pub id: String,
    pub order_id: String,
    pub product_id: String,
    pub variant_id: Option<String>,
    pub product_name: String,
    pub unit_price_paise: i64,
    pub quantity: i64,
    pub tax_rate: f64,
    pub discount_amount_paise: i64,
    pub line_total_paise: i64,
    pub notes: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct PosKotDomain {
    pub id: String,
    pub order_id: String,
    pub kot_number: i64,
    pub device_id: Option<String>,
    pub status: String,
    pub printed_at: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct KotItemDomain {
    pub id: String,
    pub kot_id: String,
    pub product_id: String,
    pub variant_id: Option<String>,
    pub product_name: String,
    pub quantity: i64,
    pub notes: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct KotCorrectionDomain {
    pub id: String,
    pub order_id: String,
    pub kot_id: Option<String>,
    pub product_name: String,
    pub cancelled_qty: i64,
    pub reason: String,
    pub authorized_by_staff_id: String,
    pub created_at: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct BillDomain {
    pub id: String,
    pub order_id: String,
    pub bill_number: String,
    pub subtotal_paise: i64,
    pub cgst_total_paise: i64,
    pub sgst_total_paise: i64,
    pub discount_total_paise: i64,
    pub grand_total_paise: i64,
    pub payment_status: String,
    pub finalized_at: String,
    pub device_id: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct PaymentDomain {
    pub id: String,
    pub bill_id: String,
    pub order_id: String,
    pub payment_mode: String,
    pub amount_paid_paise: i64,
    pub confirmed_by_staff_id: Option<String>,
    pub confirmed_at: String,
    pub notes: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct SaveInventoryMovementInput {
    pub id: Option<String>,
    pub product_id: String,
    pub movement_type: String,
    pub quantity_change: i64,
    pub created_by_staff_id: Option<String>,
    pub reference_movement_id: Option<String>,
    pub created_at: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct OutboxRow {
    pub seq: i64,
    pub id: String,
    pub entity_type: String,
    pub entity_id: String,
    pub operation: String,
    pub payload_json: String,
    pub created_at: String,
    pub attempt_count: i64,
    pub next_attempt_at: Option<String>,
    pub last_error: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct SyncCursor {
    pub dataset: String,
    pub last_updated_at: String,
    pub last_id: String,
    pub updated_at: String,
}

#[derive(Debug, Serialize, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PullDataset {
    Categories,
    Products,
    ProductVariants,
    Customers,
    PosTables,
    TableSessions,
    Orders,
    OrderItems,
    PosKots,
    KotItems,
    KotCorrections,
    Bills,
    Payments,
    InventoryLite,
}

impl PullDataset {
    pub fn as_str(&self) -> &'static str {
        match self {
            PullDataset::Categories => "categories",
            PullDataset::Products => "products",
            PullDataset::ProductVariants => "product_variants",
            PullDataset::Customers => "customers",
            PullDataset::PosTables => "pos_tables",
            PullDataset::TableSessions => "table_sessions",
            PullDataset::Orders => "orders",
            PullDataset::OrderItems => "order_items",
            PullDataset::PosKots => "pos_kots",
            PullDataset::KotItems => "kot_items",
            PullDataset::KotCorrections => "kot_corrections",
            PullDataset::Bills => "bills",
            PullDataset::Payments => "payments",
            PullDataset::InventoryLite => "inventory_lite",
        }
    }
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct CursorWatermark {
    pub last_updated_at: String,
    pub last_id: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ApplyPullBatchInput {
    pub dataset: PullDataset,
    pub rows: Vec<serde_json::Value>,
    pub new_cursor: CursorWatermark,
}

// --- Operation Results ---

#[derive(Debug, Serialize, Deserialize)]
pub struct SaveOrderResult {
    pub order: OrderDomain,
    pub items: Vec<OrderItemDomain>,
    pub outbox_entries: Vec<OutboxRow>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SaveKotResult {
    pub kot: PosKotDomain,
    pub items: Vec<KotItemDomain>,
    pub outbox_entries: Vec<OutboxRow>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SaveBillWithSequenceResult {
    pub bill: BillDomain,
    pub sequence_number: i64,
    pub outbox_entry: OutboxRow,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SavePaymentResult {
    pub payment: PaymentDomain,
    pub updated_bill: BillDomain,
    pub outbox_entry: OutboxRow,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SaveInventoryMovementResult {
    pub movement_id: String,
    pub product_id: String,
    pub new_stock: i64,
    pub outbox_entry: OutboxRow,
}

// --- Native IPC Command Enums ---

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload")]
pub enum NativeMutation {
    SetDeviceConfig(SetDeviceConfigInput),
    SaveOrderAggregate {
        order: OrderDomain,
        items: Vec<OrderItemDomain>,
    },
    SaveKotAggregate {
        kot: PosKotDomain,
        items: Vec<KotItemDomain>,
    },
    SaveKotCorrection(KotCorrectionDomain),
    SaveBillWithSequence(BillDomain),
    SavePayment {
        payment: PaymentDomain,
        updated_bill: BillDomain,
    },
    SaveInventoryMovement(SaveInventoryMovementInput),
    AcknowledgeOutbox {
        seq: i64,
    },
    UpdateOutboxFailure {
        seq: i64,
        error: String,
        next_attempt_at: Option<String>,
    },
    ApplyPullBatch(ApplyPullBatchInput),
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload")]
pub enum NativeQuery {
    GetDeviceConfig,
    GetPendingOutbox { limit: Option<i64> },
    GetSyncCursor { dataset: PullDataset },
}

// --- Helpers ---

fn now_iso() -> String {
    let now = std::time::SystemTime::now();
    let duration = now.duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    let secs = duration.as_secs();
    let millis = duration.subsec_millis();
    // Deterministic timestamp format
    format!("{}.{:03}Z", secs, millis)
}

fn generate_uuid(conn: &Connection) -> String {
    conn.query_row(
        "SELECT lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))",
        [],
        |r| r.get(0),
    ).unwrap_or_else(|_| format!("id-{}", now_iso()))
}

fn has_pending_outbox_record(conn: &Connection, entity_id: &str) -> Result<bool, rusqlite::Error> {
    let mut stmt = conn.prepare_cached("SELECT 1 FROM sync_outbox WHERE entity_id = ? LIMIT 1;")?;
    let exists = stmt.exists([entity_id])?;
    Ok(exists)
}

fn insert_outbox_record(
    conn: &Connection,
    entity_type: &str,
    entity_id: &str,
    operation: &str,
    payload: &serde_json::Value,
    created_at: &str,
) -> Result<OutboxRow, rusqlite::Error> {
    let outbox_id = generate_uuid(conn);
    let payload_json = payload.to_string();

    conn.execute(
        "INSERT INTO sync_outbox (id, entity_type, entity_id, operation, payload_json, created_at, attempt_count)
         VALUES (?, ?, ?, ?, ?, ?, 0);",
        params![outbox_id, entity_type, entity_id, operation, payload_json, created_at],
    )?;

    let seq = conn.last_insert_rowid();

    Ok(OutboxRow {
        seq,
        id: outbox_id,
        entity_type: entity_type.to_string(),
        entity_id: entity_id.to_string(),
        operation: operation.to_string(),
        payload_json,
        created_at: created_at.to_string(),
        attempt_count: 0,
        next_attempt_at: None,
        last_error: None,
    })
}

pub fn allocate_next_sequence(conn: &Connection, sequence_name: &str) -> Result<i64, rusqlite::Error> {
    let now = now_iso();
    let existing: Option<i64> = conn
        .query_row(
            "SELECT current_value FROM pos_sequences WHERE sequence_name = ?;",
            params![sequence_name],
            |r| r.get(0),
        )
        .optional()?;

    match existing {
        None => {
            conn.execute(
                "INSERT INTO pos_sequences (sequence_name, current_value, updated_at) VALUES (?, 1, ?);",
                params![sequence_name, now],
            )?;
            Ok(1)
        }
        Some(val) => {
            let next_val = val + 1;
            conn.execute(
                "UPDATE pos_sequences SET current_value = ?, updated_at = ? WHERE sequence_name = ?;",
                params![next_val, now, sequence_name],
            )?;
            Ok(next_val)
        }
    }
}

pub fn format_bill_number(terminal_code: &str, sequence_number: i64) -> String {
    let code = terminal_code.trim().to_uppercase();
    format!("CB-{code}-{sequence_number:06}")
}

// --- Core Database Engine API ---

pub fn init_database(conn: &Connection) -> Result<(), rusqlite::Error> {
    conn.execute_batch("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;")?;
    conn.execute_batch(INITIAL_SCHEMA_SQL)?;
    conn.execute_batch("PRAGMA user_version = 2;")?;
    Ok(())
}

pub fn get_device_config(conn: &Connection) -> Result<Option<DeviceConfig>, rusqlite::Error> {
    let mut stmt = conn.prepare_cached(
        "SELECT device_id, terminal_code, device_name, created_at FROM pos_device_config LIMIT 1;",
    )?;
    stmt.query_row([], |row| {
        Ok(DeviceConfig {
            device_id: row.get(0)?,
            terminal_code: row.get(1)?,
            device_name: row.get(2)?,
            created_at: row.get(3)?,
        })
    })
    .optional()
}

pub fn set_device_config(
    conn: &mut Connection,
    input: SetDeviceConfigInput,
) -> Result<DeviceConfig, String> {
    let terminal_code = input.terminal_code.trim().to_uppercase();
    if terminal_code.len() < 2 {
        return Err(format!(
            "Invalid terminal_code '{}': must be at least 2 alphanumeric characters",
            input.terminal_code
        ));
    }
    if input.device_id.trim().is_empty() {
        return Err("device_id cannot be empty".to_string());
    }
    if input.device_name.trim().is_empty() {
        return Err("device_name cannot be empty".to_string());
    }

    let created_at = input.created_at.unwrap_or_else(now_iso);

    let tx = conn.transaction().map_err(|e| e.to_string())?;
    tx.execute("DELETE FROM pos_device_config;", [])
        .map_err(|e| e.to_string())?;
    tx.execute(
        "INSERT INTO pos_device_config (device_id, terminal_code, device_name, created_at) VALUES (?, ?, ?, ?);",
        params![input.device_id, terminal_code, input.device_name, created_at],
    )
    .map_err(|e| e.to_string())?;
    tx.commit().map_err(|e| e.to_string())?;

    Ok(DeviceConfig {
        device_id: input.device_id,
        terminal_code,
        device_name: input.device_name,
        created_at,
    })
}

pub fn save_order_aggregate(
    conn: &mut Connection,
    order: OrderDomain,
    items: Vec<OrderItemDomain>,
) -> Result<SaveOrderResult, String> {
    let tx = conn.transaction().map_err(|e| e.to_string())?;

    // 1. Insert order header
    tx.execute(
        "INSERT INTO orders (
            id, display_number, channel, order_type, customer_id, table_session_id,
            status, subtotal_paise, tax_total_paise, discount_total_paise,
            delivery_charge_paise, grand_total_paise, device_id, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
        params![
            order.id,
            order.display_number,
            order.channel,
            order.order_type,
            order.customer_id,
            order.table_session_id,
            order.status,
            order.subtotal_paise,
            order.tax_total_paise,
            order.discount_total_paise,
            order.delivery_charge_paise,
            order.grand_total_paise,
            order.device_id,
            order.created_at,
            order.updated_at,
        ],
    )
    .map_err(|e| e.to_string())?;

    // 2. Insert order items
    {
        let mut item_stmt = tx
            .prepare_cached(
                "INSERT INTO order_items (
                    id, order_id, product_id, variant_id, product_name, unit_price_paise,
                    quantity, tax_rate, discount_amount_paise, line_total_paise, notes, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
            )
            .map_err(|e| e.to_string())?;

        for item in &items {
            item_stmt
                .execute(params![
                    item.id,
                    item.order_id,
                    item.product_id,
                    item.variant_id,
                    item.product_name,
                    item.unit_price_paise,
                    item.quantity,
                    item.tax_rate,
                    item.discount_amount_paise,
                    item.line_total_paise,
                    item.notes,
                    item.created_at,
                ])
                .map_err(|e| e.to_string())?;
        }
    }

    // 3. Outbox insertion
    let payload = serde_json::json!({
        "order": order,
        "items": items,
    });
    let outbox_row = insert_outbox_record(
        &tx,
        "orders",
        &order.id,
        "INSERT",
        &payload,
        &order.created_at,
    )
    .map_err(|e| e.to_string())?;

    tx.commit().map_err(|e| e.to_string())?;

    Ok(SaveOrderResult {
        order,
        items,
        outbox_entries: vec![outbox_row],
    })
}

pub fn save_kot_aggregate(
    conn: &mut Connection,
    kot: PosKotDomain,
    items: Vec<KotItemDomain>,
) -> Result<SaveKotResult, String> {
    let tx = conn.transaction().map_err(|e| e.to_string())?;

    // 1. Insert KOT header
    tx.execute(
        "INSERT INTO pos_kots (id, order_id, kot_number, device_id, status, printed_at)
         VALUES (?, ?, ?, ?, ?, ?);",
        params![
            kot.id,
            kot.order_id,
            kot.kot_number,
            kot.device_id,
            kot.status,
            kot.printed_at,
        ],
    )
    .map_err(|e| e.to_string())?;

    // 2. Insert KOT items
    {
        let mut item_stmt = tx
            .prepare_cached(
                "INSERT INTO kot_items (id, kot_id, product_id, variant_id, product_name, quantity, notes)
                 VALUES (?, ?, ?, ?, ?, ?, ?);",
            )
            .map_err(|e| e.to_string())?;

        for item in &items {
            item_stmt
                .execute(params![
                    item.id,
                    item.kot_id,
                    item.product_id,
                    item.variant_id,
                    item.product_name,
                    item.quantity,
                    item.notes,
                ])
                .map_err(|e| e.to_string())?;
        }
    }

    // 3. Outbox insertion
    let payload = serde_json::json!({
        "kot": kot,
        "items": items,
    });
    let outbox_row = insert_outbox_record(
        &tx,
        "pos_kots",
        &kot.id,
        "INSERT",
        &payload,
        &kot.printed_at,
    )
    .map_err(|e| e.to_string())?;

    tx.commit().map_err(|e| e.to_string())?;

    Ok(SaveKotResult {
        kot,
        items,
        outbox_entries: vec![outbox_row],
    })
}

pub fn save_kot_correction(
    conn: &mut Connection,
    correction: KotCorrectionDomain,
) -> Result<OutboxRow, String> {
    let tx = conn.transaction().map_err(|e| e.to_string())?;

    tx.execute(
        "INSERT INTO kot_corrections (
            id, order_id, kot_id, product_name, cancelled_qty, reason, authorized_by_staff_id, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
        params![
            correction.id,
            correction.order_id,
            correction.kot_id,
            correction.product_name,
            correction.cancelled_qty,
            correction.reason,
            correction.authorized_by_staff_id,
            correction.created_at,
        ],
    )
    .map_err(|e| e.to_string())?;

    let payload = serde_json::json!({ "correction": correction });
    let outbox_row = insert_outbox_record(
        &tx,
        "kot_corrections",
        &correction.id,
        "INSERT",
        &payload,
        &correction.created_at,
    )
    .map_err(|e| e.to_string())?;

    tx.commit().map_err(|e| e.to_string())?;

    Ok(outbox_row)
}

pub fn save_bill_with_sequence(
    conn: &mut Connection,
    mut bill: BillDomain,
) -> Result<SaveBillWithSequenceResult, String> {
    let tx = conn.transaction().map_err(|e| e.to_string())?;

    // 1. Verify terminal configuration
    let config = get_device_config(&tx)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| {
            "[PosPersistence] Terminal device identity is not configured locally. Bill allocation rejected.".to_string()
        })?;

    // 2. Allocate sequence & format authoritative bill number
    let sequence_number = allocate_next_sequence(&tx, "bill_sequence").map_err(|e| e.to_string())?;
    let authoritative_bill_number = format_bill_number(&config.terminal_code, sequence_number);

    // 3. HARD GATE: Reject conflicting caller-supplied bill number
    let caller_bill = bill.bill_number.trim();
    let is_placeholder = caller_bill.is_empty()
        || matches!(
            caller_bill.to_uppercase().as_str(),
            "PENDING" | "DRAFT" | "TEMP" | "UNASSIGNED"
        );

    if !is_placeholder && caller_bill != authoritative_bill_number {
        return Err(format!(
            "[PosPersistence] BILL_NUMBER_CONFLICT: Caller-provided bill_number \"{}\" conflicts with allocated sequence number \"{}\". Authority is NATIVE_SAVE_BILL_WITH_SEQUENCE_TRANSACTION.",
            bill.bill_number, authoritative_bill_number
        ));
    }

    bill.bill_number = authoritative_bill_number.clone();
    bill.device_id = Some(config.device_id);

    // 4. Insert bill header
    tx.execute(
        "INSERT INTO bills (
            id, order_id, bill_number, subtotal_paise, cgst_total_paise, sgst_total_paise,
            discount_total_paise, grand_total_paise, payment_status, finalized_at, device_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
        params![
            bill.id,
            bill.order_id,
            bill.bill_number,
            bill.subtotal_paise,
            bill.cgst_total_paise,
            bill.sgst_total_paise,
            bill.discount_total_paise,
            bill.grand_total_paise,
            bill.payment_status,
            bill.finalized_at,
            bill.device_id,
        ],
    )
    .map_err(|e| e.to_string())?;

    // 5. Outbox insertion
    let payload = serde_json::json!({ "bill": bill });
    let outbox_row = insert_outbox_record(
        &tx,
        "bills",
        &bill.id,
        "INSERT",
        &payload,
        &bill.finalized_at,
    )
    .map_err(|e| e.to_string())?;

    tx.commit().map_err(|e| e.to_string())?;

    Ok(SaveBillWithSequenceResult {
        bill,
        sequence_number,
        outbox_entry: outbox_row,
    })
}

pub fn save_payment(
    conn: &mut Connection,
    payment: PaymentDomain,
    updated_bill: BillDomain,
) -> Result<SavePaymentResult, String> {
    let tx = conn.transaction().map_err(|e| e.to_string())?;

    // 1. Insert payment record
    tx.execute(
        "INSERT INTO payments (
            id, bill_id, order_id, payment_mode, amount_paid_paise, confirmed_by_staff_id, confirmed_at, notes
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
        params![
            payment.id,
            payment.bill_id,
            payment.order_id,
            payment.payment_mode,
            payment.amount_paid_paise,
            payment.confirmed_by_staff_id,
            payment.confirmed_at,
            payment.notes,
        ],
    )
    .map_err(|e| e.to_string())?;

    // 2. Update bill payment status
    tx.execute(
        "UPDATE bills SET payment_status = ? WHERE id = ?;",
        params![updated_bill.payment_status, updated_bill.id],
    )
    .map_err(|e| e.to_string())?;

    // 3. Outbox insertion
    let payload = serde_json::json!({
        "payment": payment,
        "paymentStatus": updated_bill.payment_status,
    });
    let outbox_row = insert_outbox_record(
        &tx,
        "payments",
        &payment.id,
        "INSERT",
        &payload,
        &payment.confirmed_at,
    )
    .map_err(|e| e.to_string())?;

    tx.commit().map_err(|e| e.to_string())?;

    Ok(SavePaymentResult {
        payment,
        updated_bill,
        outbox_entry: outbox_row,
    })
}

pub fn save_inventory_movement(
    conn: &mut Connection,
    input: SaveInventoryMovementInput,
) -> Result<SaveInventoryMovementResult, String> {
    let tx = conn.transaction().map_err(|e| e.to_string())?;

    let movement_id = input.id.unwrap_or_else(|| generate_uuid(&tx));
    let created_at = input.created_at.unwrap_or_else(now_iso);

    // 1. Insert movement record
    tx.execute(
        "INSERT INTO inventory_movements (
            id, product_id, movement_type, quantity_change, created_by, reference_movement_id, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?);",
        params![
            movement_id,
            input.product_id,
            input.movement_type,
            input.quantity_change,
            input.created_by_staff_id,
            input.reference_movement_id,
            created_at,
        ],
    )
    .map_err(|e| e.to_string())?;

    // 2. Update inventory_lite count
    tx.execute(
        "UPDATE inventory_lite
         SET current_stock = current_stock + ?, updated_at = ?
         WHERE product_id = ?;",
        params![input.quantity_change, created_at, input.product_id],
    )
    .map_err(|e| e.to_string())?;

    let new_stock: i64 = tx
        .query_row(
            "SELECT current_stock FROM inventory_lite WHERE product_id = ?;",
            params![input.product_id],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?
        .unwrap_or(0);

    // 3. Outbox insertion
    let payload = serde_json::json!({
        "movementId": movement_id,
        "productId": input.product_id,
        "quantityChange": input.quantity_change,
        "movementType": input.movement_type,
        "createdByStaffId": input.created_by_staff_id,
        "referenceMovementId": input.reference_movement_id,
        "createdAt": created_at,
    });
    let outbox_row = insert_outbox_record(
        &tx,
        "inventory_movements",
        &movement_id,
        "INSERT",
        &payload,
        &created_at,
    )
    .map_err(|e| e.to_string())?;

    tx.commit().map_err(|e| e.to_string())?;

    Ok(SaveInventoryMovementResult {
        movement_id,
        product_id: input.product_id,
        new_stock,
        outbox_entry: outbox_row,
    })
}

pub fn get_pending_outbox(
    conn: &Connection,
    limit: Option<i64>,
) -> Result<Vec<OutboxRow>, rusqlite::Error> {
    let limit = limit.unwrap_or(10).min(10);
    let mut stmt = conn.prepare_cached(
        "SELECT seq, id, entity_type, entity_id, operation, payload_json, created_at, attempt_count, next_attempt_at, last_error
         FROM sync_outbox
         ORDER BY seq ASC
         LIMIT ?;",
    )?;

    let rows = stmt.query_map([limit], |row| {
        Ok(OutboxRow {
            seq: row.get(0)?,
            id: row.get(1)?,
            entity_type: row.get(2)?,
            entity_id: row.get(3)?,
            operation: row.get(4)?,
            payload_json: row.get(5)?,
            created_at: row.get(6)?,
            attempt_count: row.get(7)?,
            next_attempt_at: row.get(8)?,
            last_error: row.get(9)?,
        })
    })?;

    let mut result = Vec::new();
    for row in rows {
        result.push(row?);
    }
    Ok(result)
}

pub fn acknowledge_outbox(conn: &mut Connection, seq: i64) -> Result<(), rusqlite::Error> {
    let tx = conn.transaction()?;
    tx.execute("DELETE FROM sync_outbox WHERE seq = ?;", [seq])?;
    tx.commit()?;
    Ok(())
}

pub fn update_outbox_failure(
    conn: &mut Connection,
    seq: i64,
    error: &str,
    next_attempt_at: Option<&str>,
) -> Result<(), rusqlite::Error> {
    let tx = conn.transaction()?;
    tx.execute(
        "UPDATE sync_outbox
         SET attempt_count = attempt_count + 1, last_error = ?, next_attempt_at = ?
         WHERE seq = ?;",
        params![error, next_attempt_at, seq],
    )?;
    tx.commit()?;
    Ok(())
}

pub fn get_sync_cursor(
    conn: &Connection,
    dataset: PullDataset,
) -> Result<SyncCursor, rusqlite::Error> {
    let dataset_str = dataset.as_str();
    let mut stmt = conn.prepare_cached(
        "SELECT dataset, last_updated_at, last_id, updated_at FROM sync_cursors WHERE dataset = ?;",
    )?;

    let cursor = stmt
        .query_row([dataset_str], |row| {
            Ok(SyncCursor {
                dataset: row.get(0)?,
                last_updated_at: row.get(1)?,
                last_id: row.get(2)?,
                updated_at: row.get(3)?,
            })
        })
        .optional()?;

    Ok(cursor.unwrap_or_else(|| SyncCursor {
        dataset: dataset_str.to_string(),
        last_updated_at: "1970-01-01T00:00:00.000Z".to_string(),
        last_id: String::new(),
        updated_at: now_iso(),
    }))
}

pub fn set_sync_cursor(
    conn: &Connection,
    dataset: PullDataset,
    last_updated_at: &str,
    last_id: &str,
) -> Result<(), rusqlite::Error> {
    let now = now_iso();
    conn.execute(
        "INSERT INTO sync_cursors (dataset, last_updated_at, last_id, updated_at)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(dataset) DO UPDATE SET
           last_updated_at = excluded.last_updated_at,
           last_id = excluded.last_id,
           updated_at = excluded.updated_at;",
        params![dataset.as_str(), last_updated_at, last_id, now],
    )?;
    Ok(())
}

fn to_paise(val: &serde_json::Value) -> i64 {
    if let Some(n) = val.as_f64() {
        (n * 100.0).round() as i64
    } else if let Some(n) = val.as_i64() {
        n * 100
    } else {
        0
    }
}

pub fn apply_pull_batch(
    conn: &mut Connection,
    input: ApplyPullBatchInput,
) -> Result<i64, String> {
    let tx = conn.transaction().map_err(|e| e.to_string())?;
    let mut rows_applied = 0;

    if input.rows.is_empty() {
        set_sync_cursor(
            &tx,
            input.dataset,
            &input.new_cursor.last_updated_at,
            &input.new_cursor.last_id,
        )
        .map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
        return Ok(0);
    }

    let existing_cursor = get_sync_cursor(&tx, input.dataset).map_err(|e| e.to_string())?;
    let mut safe_last_updated_at = existing_cursor.last_updated_at;
    let mut safe_last_id = existing_cursor.last_id;
    let mut hit_pending_protection = false;

    match input.dataset {
        PullDataset::Categories => {
            let mut stmt = tx
                .prepare_cached(
                    "INSERT INTO categories (id, name, slug, display_order, is_active, created_at, updated_at)
                     VALUES (?, ?, ?, ?, ?, ?, ?)
                     ON CONFLICT(id) DO UPDATE SET
                       name = excluded.name,
                       slug = excluded.slug,
                       display_order = excluded.display_order,
                       is_active = excluded.is_active,
                       created_at = excluded.created_at,
                       updated_at = excluded.updated_at;",
                )
                .map_err(|e| e.to_string())?;

            for row in &input.rows {
                let id = row["id"].as_str().unwrap_or("");
                if has_pending_outbox_record(&tx, id).map_err(|e| e.to_string())? {
                    hit_pending_protection = true;
                    break;
                }
                stmt.execute(params![
                    id,
                    row["name"].as_str().unwrap_or(""),
                    row["slug"].as_str().unwrap_or(id),
                    row["display_order"].as_i64().or_else(|| row["sort_order"].as_i64()).unwrap_or(0),
                    if row["is_active"].as_bool().unwrap_or(true) { 1 } else { 0 },
                    row["created_at"].as_str().unwrap_or(&now_iso()),
                    row["updated_at"].as_str().unwrap_or(&now_iso()),
                ])
                .map_err(|e| e.to_string())?;
                rows_applied += 1;
                safe_last_updated_at = row["updated_at"].as_str().or_else(|| row["created_at"].as_str()).unwrap_or(&now_iso()).to_string();
                safe_last_id = id.to_string();
            }
        }
        PullDataset::Products => {
            let mut stmt = tx
                .prepare_cached(
                    "INSERT INTO products (id, category_id, name, description, image_url, base_price_paise, is_available, tax_rate, is_inventory_tracked, created_at, updated_at)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                     ON CONFLICT(id) DO UPDATE SET
                       category_id = excluded.category_id,
                       name = excluded.name,
                       description = excluded.description,
                       image_url = excluded.image_url,
                       base_price_paise = excluded.base_price_paise,
                       is_available = excluded.is_available,
                       tax_rate = excluded.tax_rate,
                       is_inventory_tracked = excluded.is_inventory_tracked,
                       created_at = excluded.created_at,
                       updated_at = excluded.updated_at;",
                )
                .map_err(|e| e.to_string())?;

            for row in &input.rows {
                let id = row["id"].as_str().unwrap_or("");
                if has_pending_outbox_record(&tx, id).map_err(|e| e.to_string())? {
                    hit_pending_protection = true;
                    break;
                }
                stmt.execute(params![
                    id,
                    row["category_id"].as_str().unwrap_or(""),
                    row["name"].as_str().unwrap_or(""),
                    row["description"].as_str(),
                    row["image_url"].as_str(),
                    to_paise(&row["base_price"]),
                    if row["is_available"].as_bool().unwrap_or(true) { 1 } else { 0 },
                    row["tax_rate"].as_f64().unwrap_or(5.0),
                    if row["is_inventory_tracked"].as_bool().unwrap_or(false) { 1 } else { 0 },
                    row["created_at"].as_str().unwrap_or(&now_iso()),
                    row["updated_at"].as_str().unwrap_or(&now_iso()),
                ])
                .map_err(|e| e.to_string())?;
                rows_applied += 1;
                safe_last_updated_at = row["updated_at"].as_str().or_else(|| row["created_at"].as_str()).unwrap_or(&now_iso()).to_string();
                safe_last_id = id.to_string();
            }
        }
        PullDataset::ProductVariants => {
            let mut stmt = tx
                .prepare_cached(
                    "INSERT INTO product_variants (id, product_id, variant_name, price_override_paise, is_available, created_at)
                     VALUES (?, ?, ?, ?, ?, ?)
                     ON CONFLICT(id) DO UPDATE SET
                       product_id = excluded.product_id,
                       variant_name = excluded.variant_name,
                       price_override_paise = excluded.price_override_paise,
                       is_available = excluded.is_available,
                       created_at = excluded.created_at;",
                )
                .map_err(|e| e.to_string())?;

            for row in &input.rows {
                let id = row["id"].as_str().unwrap_or("");
                if has_pending_outbox_record(&tx, id).map_err(|e| e.to_string())? {
                    hit_pending_protection = true;
                    break;
                }
                let price_override = if row["price_override"].is_null() {
                    None
                } else {
                    Some(to_paise(&row["price_override"]))
                };
                stmt.execute(params![
                    id,
                    row["product_id"].as_str().unwrap_or(""),
                    row["variant_name"].as_str().unwrap_or(""),
                    price_override,
                    if row["is_available"].as_bool().unwrap_or(true) { 1 } else { 0 },
                    row["created_at"].as_str().unwrap_or(&now_iso()),
                ])
                .map_err(|e| e.to_string())?;
                rows_applied += 1;
                safe_last_updated_at = row["created_at"].as_str().unwrap_or(&now_iso()).to_string();
                safe_last_id = id.to_string();
            }
        }
        PullDataset::Customers => {
            let mut stmt = tx
                .prepare_cached(
                    "INSERT INTO customers (id, phone, full_name, email, is_active, created_at, updated_at)
                     VALUES (?, ?, ?, ?, ?, ?, ?)
                     ON CONFLICT(id) DO UPDATE SET
                       phone = excluded.phone,
                       full_name = excluded.full_name,
                       email = excluded.email,
                       is_active = excluded.is_active,
                       created_at = excluded.created_at,
                       updated_at = excluded.updated_at;",
                )
                .map_err(|e| e.to_string())?;

            for row in &input.rows {
                let id = row["id"].as_str().unwrap_or("");
                if has_pending_outbox_record(&tx, id).map_err(|e| e.to_string())? {
                    hit_pending_protection = true;
                    break;
                }
                stmt.execute(params![
                    id,
                    row["phone"].as_str().unwrap_or(""),
                    row["full_name"].as_str().or_else(|| row["name"].as_str()),
                    row["email"].as_str(),
                    if row["is_active"].as_bool().unwrap_or(true) { 1 } else { 0 },
                    row["created_at"].as_str().unwrap_or(&now_iso()),
                    row["updated_at"].as_str().unwrap_or(&now_iso()),
                ])
                .map_err(|e| e.to_string())?;
                rows_applied += 1;
                safe_last_updated_at = row["updated_at"].as_str().or_else(|| row["created_at"].as_str()).unwrap_or(&now_iso()).to_string();
                safe_last_id = id.to_string();
            }
        }
        PullDataset::PosTables => {
            let mut stmt = tx
                .prepare_cached(
                    "INSERT INTO pos_tables (id, table_number, section, capacity, is_active, created_at)
                     VALUES (?, ?, ?, ?, ?, ?)
                     ON CONFLICT(id) DO UPDATE SET
                       table_number = excluded.table_number,
                       section = excluded.section,
                       capacity = excluded.capacity,
                       is_active = excluded.is_active,
                       created_at = excluded.created_at;",
                )
                .map_err(|e| e.to_string())?;

            for row in &input.rows {
                let id = row["id"].as_str().unwrap_or("");
                if has_pending_outbox_record(&tx, id).map_err(|e| e.to_string())? {
                    hit_pending_protection = true;
                    break;
                }
                stmt.execute(params![
                    id,
                    row["table_number"].as_str().unwrap_or(""),
                    row["section"].as_str().unwrap_or("Main Floor"),
                    row["capacity"].as_i64().unwrap_or(4),
                    if row["is_active"].as_bool().unwrap_or(true) { 1 } else { 0 },
                    row["created_at"].as_str().unwrap_or(&now_iso()),
                ])
                .map_err(|e| e.to_string())?;
                rows_applied += 1;
                safe_last_updated_at = row["created_at"].as_str().unwrap_or(&now_iso()).to_string();
                safe_last_id = id.to_string();
            }
        }
        PullDataset::TableSessions => {
            let mut stmt = tx
                .prepare_cached(
                    "INSERT INTO table_sessions (id, table_id, current_order_id, guest_count, session_status, opened_at, closed_at)
                     VALUES (?, ?, ?, ?, ?, ?, ?)
                     ON CONFLICT(id) DO UPDATE SET
                       table_id = excluded.table_id,
                       current_order_id = excluded.current_order_id,
                       guest_count = excluded.guest_count,
                       session_status = excluded.session_status,
                       opened_at = excluded.opened_at,
                       closed_at = excluded.closed_at;",
                )
                .map_err(|e| e.to_string())?;

            for row in &input.rows {
                let id = row["id"].as_str().unwrap_or("");
                if has_pending_outbox_record(&tx, id).map_err(|e| e.to_string())? {
                    hit_pending_protection = true;
                    break;
                }
                stmt.execute(params![
                    id,
                    row["table_id"].as_str().unwrap_or(""),
                    row["current_order_id"].as_str(),
                    row["guest_count"].as_i64().unwrap_or(1),
                    row["session_status"].as_str().unwrap_or("open"),
                    row["opened_at"].as_str().unwrap_or(&now_iso()),
                    row["closed_at"].as_str(),
                ])
                .map_err(|e| e.to_string())?;
                rows_applied += 1;
                safe_last_updated_at = row["opened_at"].as_str().unwrap_or(&now_iso()).to_string();
                safe_last_id = id.to_string();
            }
        }
        PullDataset::Orders => {
            let mut order_stmt = tx
                .prepare_cached(
                    "INSERT INTO orders (id, display_number, channel, order_type, customer_id, table_session_id, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, device_id, created_at, updated_at)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                     ON CONFLICT(id) DO UPDATE SET
                       display_number = excluded.display_number,
                       channel = excluded.channel,
                       order_type = excluded.order_type,
                       customer_id = excluded.customer_id,
                       table_session_id = excluded.table_session_id,
                       status = excluded.status,
                       subtotal_paise = excluded.subtotal_paise,
                       tax_total_paise = excluded.tax_total_paise,
                       discount_total_paise = excluded.discount_total_paise,
                       delivery_charge_paise = excluded.delivery_charge_paise,
                       grand_total_paise = excluded.grand_total_paise,
                       device_id = excluded.device_id,
                       created_at = excluded.created_at,
                       updated_at = excluded.updated_at;",
                )
                .map_err(|e| e.to_string())?;

            let mut item_stmt = tx
                .prepare_cached(
                    "INSERT INTO order_items (id, order_id, product_id, variant_id, product_name, unit_price_paise, quantity, tax_rate, discount_amount_paise, line_total_paise, notes, created_at)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                     ON CONFLICT(id) DO UPDATE SET
                       order_id = excluded.order_id,
                       product_id = excluded.product_id,
                       variant_id = excluded.variant_id,
                       product_name = excluded.product_name,
                       unit_price_paise = excluded.unit_price_paise,
                       quantity = excluded.quantity,
                       tax_rate = excluded.tax_rate,
                       discount_amount_paise = excluded.discount_amount_paise,
                       line_total_paise = excluded.line_total_paise,
                       notes = excluded.notes,
                       created_at = excluded.created_at;",
                )
                .map_err(|e| e.to_string())?;

            // Normalize input format: may be [{ "orders": [...], "orderItems": [...] }] or array of orders
            let (order_list, item_list): (Vec<&serde_json::Value>, Vec<&serde_json::Value>) =
                if input.rows.len() == 1 && (input.rows[0].get("orders").is_some() || input.rows[0].get("orderItems").is_some()) {
                    let ords = input.rows[0]["orders"].as_array().map(|v| v.iter().collect()).unwrap_or_default();
                    let items = input.rows[0]["orderItems"].as_array().map(|v| v.iter().collect()).unwrap_or_default();
                    (ords, items)
                } else {
                    let ords: Vec<&serde_json::Value> = input.rows.iter().collect();
                    let mut items = Vec::new();
                    for ord in &input.rows {
                        if let Some(arr) = ord["items"].as_array() {
                            items.extend(arr.iter());
                        }
                    }
                    (ords, items)
                };

            for order in order_list {
                let id = order["id"].as_str().unwrap_or("");
                let mut is_order_pending = has_pending_outbox_record(&tx, id).map_err(|e| e.to_string())?;
                if !is_order_pending {
                    for item in &item_list {
                        if item["order_id"].as_str() == Some(id) {
                            let item_id = item["id"].as_str().unwrap_or("");
                            if has_pending_outbox_record(&tx, item_id).map_err(|e| e.to_string())? {
                                is_order_pending = true;
                                break;
                            }
                        }
                    }
                }

                if is_order_pending {
                    hit_pending_protection = true;
                    break;
                }

                order_stmt
                    .execute(params![
                        id,
                        order["display_number"].as_str(),
                        order["channel"].as_str().unwrap_or("POS"),
                        order["order_type"].as_str().unwrap_or("DINE_IN"),
                        order["customer_id"].as_str(),
                        order["table_session_id"].as_str(),
                        order["status"].as_str().unwrap_or("draft"),
                        to_paise(&order["subtotal"]),
                        to_paise(&order["tax_total"]),
                        to_paise(&order["discount_total"]),
                        to_paise(&order["delivery_charge"]),
                        to_paise(&order["grand_total"]),
                        order["device_id"].as_str(),
                        order["created_at"].as_str().unwrap_or(&now_iso()),
                        order["updated_at"].as_str().unwrap_or(&now_iso()),
                    ])
                    .map_err(|e| e.to_string())?;
                rows_applied += 1;

                for item in &item_list {
                    if item["order_id"].as_str() == Some(id) {
                        let item_id = item["id"].as_str().unwrap_or("");
                        item_stmt
                            .execute(params![
                                item_id,
                                id,
                                item["product_id"].as_str().unwrap_or(""),
                                item["variant_id"].as_str(),
                                item["product_name"].as_str().unwrap_or(""),
                                to_paise(&item["unit_price"]),
                                item["quantity"].as_i64().unwrap_or(1),
                                item["tax_rate"].as_f64().unwrap_or(5.0),
                                to_paise(&item["discount_amount"]),
                                to_paise(&item["line_total"]),
                                item["notes"].as_str(),
                                item["created_at"].as_str().unwrap_or(&now_iso()),
                            ])
                            .map_err(|e| e.to_string())?;
                        rows_applied += 1;
                    }
                }

                safe_last_updated_at = order["updated_at"].as_str().unwrap_or(&now_iso()).to_string();
                safe_last_id = id.to_string();
            }
        }
        PullDataset::OrderItems => {
            let mut stmt = tx
                .prepare_cached(
                    "INSERT INTO order_items (id, order_id, product_id, variant_id, product_name, unit_price_paise, quantity, tax_rate, discount_amount_paise, line_total_paise, notes, created_at)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                     ON CONFLICT(id) DO UPDATE SET
                       order_id = excluded.order_id,
                       product_id = excluded.product_id,
                       variant_id = excluded.variant_id,
                       product_name = excluded.product_name,
                       unit_price_paise = excluded.unit_price_paise,
                       quantity = excluded.quantity,
                       tax_rate = excluded.tax_rate,
                       discount_amount_paise = excluded.discount_amount_paise,
                       line_total_paise = excluded.line_total_paise,
                       notes = excluded.notes,
                       created_at = excluded.created_at;",
                )
                .map_err(|e| e.to_string())?;

            for row in &input.rows {
                let id = row["id"].as_str().unwrap_or("");
                let order_id = row["order_id"].as_str().unwrap_or("");
                if has_pending_outbox_record(&tx, order_id).map_err(|e| e.to_string())?
                    || has_pending_outbox_record(&tx, id).map_err(|e| e.to_string())?
                {
                    hit_pending_protection = true;
                    break;
                }
                stmt.execute(params![
                    id,
                    order_id,
                    row["product_id"].as_str().unwrap_or(""),
                    row["variant_id"].as_str(),
                    row["product_name"].as_str().unwrap_or(""),
                    to_paise(&row["unit_price"]),
                    row["quantity"].as_i64().unwrap_or(1),
                    row["tax_rate"].as_f64().unwrap_or(5.0),
                    to_paise(&row["discount_amount"]),
                    to_paise(&row["line_total"]),
                    row["notes"].as_str(),
                    row["created_at"].as_str().unwrap_or(&now_iso()),
                ])
                .map_err(|e| e.to_string())?;
                rows_applied += 1;
                safe_last_updated_at = row["created_at"].as_str().unwrap_or(&now_iso()).to_string();
                safe_last_id = id.to_string();
            }
        }
        PullDataset::PosKots => {
            let mut kot_stmt = tx
                .prepare_cached(
                    "INSERT INTO pos_kots (id, order_id, kot_number, device_id, status, printed_at)
                     VALUES (?, ?, ?, ?, ?, ?)
                     ON CONFLICT(id) DO UPDATE SET
                       order_id = excluded.order_id,
                       kot_number = excluded.kot_number,
                       device_id = excluded.device_id,
                       status = excluded.status,
                       printed_at = excluded.printed_at;",
                )
                .map_err(|e| e.to_string())?;

            let mut item_stmt = tx
                .prepare_cached(
                    "INSERT INTO kot_items (id, kot_id, product_id, variant_id, product_name, quantity, notes)
                     VALUES (?, ?, ?, ?, ?, ?, ?)
                     ON CONFLICT(id) DO UPDATE SET
                       kot_id = excluded.kot_id,
                       product_id = excluded.product_id,
                       variant_id = excluded.variant_id,
                       product_name = excluded.product_name,
                       quantity = excluded.quantity,
                       notes = excluded.notes;",
                )
                .map_err(|e| e.to_string())?;

            let (kot_list, item_list): (Vec<&serde_json::Value>, Vec<&serde_json::Value>) =
                if input.rows.len() == 1 && (input.rows[0].get("kots").is_some() || input.rows[0].get("kotItems").is_some()) {
                    let kots = input.rows[0]["kots"].as_array().map(|v| v.iter().collect()).unwrap_or_default();
                    let items = input.rows[0]["kotItems"].as_array().map(|v| v.iter().collect()).unwrap_or_default();
                    (kots, items)
                } else {
                    let kots: Vec<&serde_json::Value> = input.rows.iter().collect();
                    let mut items = Vec::new();
                    for kot in &input.rows {
                        if let Some(arr) = kot["items"].as_array() {
                            items.extend(arr.iter());
                        }
                    }
                    (kots, items)
                };

            for kot in kot_list {
                let id = kot["id"].as_str().unwrap_or("");
                let order_id = kot["order_id"].as_str().unwrap_or("");
                let mut is_kot_pending = has_pending_outbox_record(&tx, id).map_err(|e| e.to_string())?
                    || has_pending_outbox_record(&tx, order_id).map_err(|e| e.to_string())?;
                if !is_kot_pending {
                    for item in &item_list {
                        if item["kot_id"].as_str() == Some(id) {
                            let item_id = item["id"].as_str().unwrap_or("");
                            if has_pending_outbox_record(&tx, item_id).map_err(|e| e.to_string())? {
                                is_kot_pending = true;
                                break;
                            }
                        }
                    }
                }

                if is_kot_pending {
                    hit_pending_protection = true;
                    break;
                }

                kot_stmt
                    .execute(params![
                        id,
                        order_id,
                        kot["kot_number"].as_i64().unwrap_or(1),
                        kot["device_id"].as_str(),
                        kot["status"].as_str().unwrap_or("printed"),
                        kot["printed_at"].as_str().unwrap_or(&now_iso()),
                    ])
                    .map_err(|e| e.to_string())?;
                rows_applied += 1;

                for item in &item_list {
                    if item["kot_id"].as_str() == Some(id) {
                        let item_id = item["id"].as_str().unwrap_or("");
                        item_stmt
                            .execute(params![
                                item_id,
                                id,
                                item["product_id"].as_str().unwrap_or(""),
                                item["variant_id"].as_str(),
                                item["product_name"].as_str().unwrap_or(""),
                                item["quantity"].as_i64().unwrap_or(1),
                                item["notes"].as_str(),
                            ])
                            .map_err(|e| e.to_string())?;
                        rows_applied += 1;
                    }
                }

                safe_last_updated_at = kot["printed_at"].as_str().unwrap_or(&now_iso()).to_string();
                safe_last_id = id.to_string();
            }
        }
        PullDataset::KotItems => {
            let mut stmt = tx
                .prepare_cached(
                    "INSERT INTO kot_items (id, kot_id, product_id, variant_id, product_name, quantity, notes)
                     VALUES (?, ?, ?, ?, ?, ?, ?)
                     ON CONFLICT(id) DO UPDATE SET
                       kot_id = excluded.kot_id,
                       product_id = excluded.product_id,
                       variant_id = excluded.variant_id,
                       product_name = excluded.product_name,
                       quantity = excluded.quantity,
                       notes = excluded.notes;",
                )
                .map_err(|e| e.to_string())?;

            for row in &input.rows {
                let id = row["id"].as_str().unwrap_or("");
                let kot_id = row["kot_id"].as_str().unwrap_or("");
                if has_pending_outbox_record(&tx, kot_id).map_err(|e| e.to_string())?
                    || has_pending_outbox_record(&tx, id).map_err(|e| e.to_string())?
                {
                    hit_pending_protection = true;
                    break;
                }
                stmt.execute(params![
                    id,
                    kot_id,
                    row["product_id"].as_str().unwrap_or(""),
                    row["variant_id"].as_str(),
                    row["product_name"].as_str().unwrap_or(""),
                    row["quantity"].as_i64().unwrap_or(1),
                    row["notes"].as_str(),
                ])
                .map_err(|e| e.to_string())?;
                rows_applied += 1;
                safe_last_updated_at = now_iso();
                safe_last_id = id.to_string();
            }
        }
        PullDataset::KotCorrections => {
            let mut stmt = tx
                .prepare_cached(
                    "INSERT INTO kot_corrections (id, order_id, kot_id, product_name, cancelled_qty, reason, authorized_by_staff_id, created_at)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                     ON CONFLICT(id) DO UPDATE SET
                       order_id = excluded.order_id,
                       kot_id = excluded.kot_id,
                       product_name = excluded.product_name,
                       cancelled_qty = excluded.cancelled_qty,
                       reason = excluded.reason,
                       authorized_by_staff_id = excluded.authorized_by_staff_id,
                       created_at = excluded.created_at;",
                )
                .map_err(|e| e.to_string())?;

            for row in &input.rows {
                let id = row["id"].as_str().unwrap_or("");
                let order_id = row["order_id"].as_str().unwrap_or("");
                if has_pending_outbox_record(&tx, id).map_err(|e| e.to_string())?
                    || has_pending_outbox_record(&tx, order_id).map_err(|e| e.to_string())?
                {
                    hit_pending_protection = true;
                    break;
                }
                stmt.execute(params![
                    id,
                    order_id,
                    row["kot_id"].as_str(),
                    row["product_name"].as_str().unwrap_or(""),
                    row["cancelled_qty"].as_i64().unwrap_or(1),
                    row["reason"].as_str().unwrap_or(""),
                    row["authorized_by_staff_id"].as_str().unwrap_or(""),
                    row["created_at"].as_str().unwrap_or(&now_iso()),
                ])
                .map_err(|e| e.to_string())?;
                rows_applied += 1;
                safe_last_updated_at = row["created_at"].as_str().unwrap_or(&now_iso()).to_string();
                safe_last_id = id.to_string();
            }
        }
        PullDataset::Bills => {
            let mut stmt = tx
                .prepare_cached(
                    "INSERT INTO bills (id, order_id, bill_number, subtotal_paise, cgst_total_paise, sgst_total_paise, discount_total_paise, grand_total_paise, payment_status, finalized_at, device_id)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                     ON CONFLICT(id) DO UPDATE SET
                       order_id = excluded.order_id,
                       bill_number = excluded.bill_number,
                       subtotal_paise = excluded.subtotal_paise,
                       cgst_total_paise = excluded.cgst_total_paise,
                       sgst_total_paise = excluded.sgst_total_paise,
                       discount_total_paise = excluded.discount_total_paise,
                       grand_total_paise = excluded.grand_total_paise,
                       payment_status = excluded.payment_status,
                       finalized_at = excluded.finalized_at,
                       device_id = excluded.device_id;",
                )
                .map_err(|e| e.to_string())?;

            for row in &input.rows {
                let id = row["id"].as_str().unwrap_or("");
                let order_id = row["order_id"].as_str().unwrap_or("");
                if has_pending_outbox_record(&tx, id).map_err(|e| e.to_string())?
                    || has_pending_outbox_record(&tx, order_id).map_err(|e| e.to_string())?
                {
                    hit_pending_protection = true;
                    break;
                }

                let pulled_grand_total = to_paise(&row["grand_total"]);

                // Financial immutability check
                let existing: Option<i64> = tx
                    .query_row(
                        "SELECT grand_total_paise FROM bills WHERE id = ?;",
                        params![id],
                        |r| r.get(0),
                    )
                    .optional()
                    .map_err(|e| e.to_string())?;

                if let Some(existing_total) = existing {
                    if existing_total != pulled_grand_total {
                        return Err(format!(
                            "CONTRACT_CONFLICT: Pulled bill {id} grand total ({pulled_grand_total} paise) conflicts with existing local bill ({existing_total} paise)"
                        ));
                    }
                }

                stmt.execute(params![
                    id,
                    order_id,
                    row["bill_number"].as_str().unwrap_or(""),
                    to_paise(&row["subtotal"]),
                    to_paise(&row["cgst_total"]),
                    to_paise(&row["sgst_total"]),
                    to_paise(&row["discount_total"]),
                    pulled_grand_total,
                    row["payment_status"].as_str().unwrap_or("unpaid"),
                    row["finalized_at"].as_str().unwrap_or(&now_iso()),
                    row["device_id"].as_str(),
                ])
                .map_err(|e| e.to_string())?;
                rows_applied += 1;
                safe_last_updated_at = row["finalized_at"].as_str().unwrap_or(&now_iso()).to_string();
                safe_last_id = id.to_string();
            }
        }
        PullDataset::Payments => {
            let mut stmt = tx
                .prepare_cached(
                    "INSERT INTO payments (id, bill_id, order_id, payment_mode, amount_paid_paise, confirmed_by_staff_id, confirmed_at, notes)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                     ON CONFLICT(id) DO UPDATE SET
                       bill_id = excluded.bill_id,
                       order_id = excluded.order_id,
                       payment_mode = excluded.payment_mode,
                       amount_paid_paise = excluded.amount_paid_paise,
                       confirmed_by_staff_id = excluded.confirmed_by_staff_id,
                       confirmed_at = excluded.confirmed_at,
                       notes = excluded.notes;",
                )
                .map_err(|e| e.to_string())?;

            for row in &input.rows {
                let id = row["id"].as_str().unwrap_or("");
                let order_id = row["order_id"].as_str().unwrap_or("");
                let bill_id = row["bill_id"].as_str().unwrap_or("");
                if has_pending_outbox_record(&tx, id).map_err(|e| e.to_string())?
                    || has_pending_outbox_record(&tx, order_id).map_err(|e| e.to_string())?
                    || has_pending_outbox_record(&tx, bill_id).map_err(|e| e.to_string())?
                {
                    hit_pending_protection = true;
                    break;
                }

                let pulled_amount = to_paise(&row["amount_paid"]);

                // Financial immutability check
                let existing: Option<i64> = tx
                    .query_row(
                        "SELECT amount_paid_paise FROM payments WHERE id = ?;",
                        params![id],
                        |r| r.get(0),
                    )
                    .optional()
                    .map_err(|e| e.to_string())?;

                if let Some(existing_amount) = existing {
                    if existing_amount != pulled_amount {
                        return Err(format!(
                            "CONTRACT_CONFLICT: Pulled payment {id} amount ({pulled_amount} paise) conflicts with existing local payment ({existing_amount} paise)"
                        ));
                    }
                }

                stmt.execute(params![
                    id,
                    bill_id,
                    order_id,
                    row["payment_mode"].as_str().unwrap_or("CASH"),
                    pulled_amount,
                    row["confirmed_by_staff_id"].as_str(),
                    row["confirmed_at"].as_str().unwrap_or(&now_iso()),
                    row["notes"].as_str(),
                ])
                .map_err(|e| e.to_string())?;
                rows_applied += 1;
                safe_last_updated_at = row["confirmed_at"].as_str().unwrap_or(&now_iso()).to_string();
                safe_last_id = id.to_string();
            }
        }
        PullDataset::InventoryLite => {
            let mut stmt = tx
                .prepare_cached(
                    "INSERT INTO inventory_lite (id, product_id, current_stock, low_stock_threshold, is_tracked, updated_at)
                     VALUES (?, ?, ?, ?, ?, ?)
                     ON CONFLICT(product_id) DO UPDATE SET
                       current_stock = excluded.current_stock,
                       low_stock_threshold = excluded.low_stock_threshold,
                       is_tracked = excluded.is_tracked,
                       updated_at = excluded.updated_at;",
                )
                .map_err(|e| e.to_string())?;

            for row in &input.rows {
                let id = row["id"].as_str().unwrap_or("");
                let product_id = row["product_id"].as_str().unwrap_or(id);
                if has_pending_outbox_record(&tx, id).map_err(|e| e.to_string())?
                    || has_pending_outbox_record(&tx, product_id).map_err(|e| e.to_string())?
                {
                    hit_pending_protection = true;
                    break;
                }
                stmt.execute(params![
                    id,
                    product_id,
                    row["current_stock"].as_i64().unwrap_or(0),
                    row["low_stock_threshold"].as_i64().unwrap_or(5),
                    if row["is_tracked"].as_bool().unwrap_or(true) { 1 } else { 0 },
                    row["updated_at"].as_str().unwrap_or(&now_iso()),
                ])
                .map_err(|e| e.to_string())?;
                rows_applied += 1;
                safe_last_updated_at = row["updated_at"].as_str().unwrap_or(&now_iso()).to_string();
                safe_last_id = product_id.to_string();
            }
        }
    }

    if !hit_pending_protection {
        set_sync_cursor(
            &tx,
            input.dataset,
            &input.new_cursor.last_updated_at,
            &input.new_cursor.last_id,
        )
        .map_err(|e| e.to_string())?;
    } else {
        set_sync_cursor(
            &tx,
            input.dataset,
            &safe_last_updated_at,
            &safe_last_id,
        )
        .map_err(|e| e.to_string())?;
    }

    tx.commit().map_err(|e| e.to_string())?;

    Ok(rows_applied)
}

// --- High-Level Dispatchers ---

pub fn execute_mutation(
    conn: &mut Connection,
    mutation: NativeMutation,
) -> Result<serde_json::Value, String> {
    match mutation {
        NativeMutation::SetDeviceConfig(input) => {
            let cfg = set_device_config(conn, input)?;
            serde_json::to_value(cfg).map_err(|e| e.to_string())
        }
        NativeMutation::SaveOrderAggregate { order, items } => {
            let res = save_order_aggregate(conn, order, items)?;
            serde_json::to_value(res).map_err(|e| e.to_string())
        }
        NativeMutation::SaveKotAggregate { kot, items } => {
            let res = save_kot_aggregate(conn, kot, items)?;
            serde_json::to_value(res).map_err(|e| e.to_string())
        }
        NativeMutation::SaveKotCorrection(correction) => {
            let res = save_kot_correction(conn, correction)?;
            serde_json::to_value(res).map_err(|e| e.to_string())
        }
        NativeMutation::SaveBillWithSequence(bill) => {
            let res = save_bill_with_sequence(conn, bill)?;
            serde_json::to_value(res).map_err(|e| e.to_string())
        }
        NativeMutation::SavePayment {
            payment,
            updated_bill,
        } => {
            let res = save_payment(conn, payment, updated_bill)?;
            serde_json::to_value(res).map_err(|e| e.to_string())
        }
        NativeMutation::SaveInventoryMovement(input) => {
            let res = save_inventory_movement(conn, input)?;
            serde_json::to_value(res).map_err(|e| e.to_string())
        }
        NativeMutation::AcknowledgeOutbox { seq } => {
            acknowledge_outbox(conn, seq).map_err(|e| e.to_string())?;
            Ok(serde_json::json!({ "acknowledged": true, "seq": seq }))
        }
        NativeMutation::UpdateOutboxFailure {
            seq,
            error,
            next_attempt_at,
        } => {
            update_outbox_failure(conn, seq, &error, next_attempt_at.as_deref())
                .map_err(|e| e.to_string())?;
            Ok(serde_json::json!({ "updated": true, "seq": seq }))
        }
        NativeMutation::ApplyPullBatch(input) => {
            let applied = apply_pull_batch(conn, input)?;
            Ok(serde_json::json!({ "rowsApplied": applied }))
        }
    }
}

pub fn execute_query(conn: &Connection, query: NativeQuery) -> Result<serde_json::Value, String> {
    match query {
        NativeQuery::GetDeviceConfig => {
            let cfg = get_device_config(conn).map_err(|e| e.to_string())?;
            serde_json::to_value(cfg).map_err(|e| e.to_string())
        }
        NativeQuery::GetPendingOutbox { limit } => {
            let rows = get_pending_outbox(conn, limit).map_err(|e| e.to_string())?;
            serde_json::to_value(rows).map_err(|e| e.to_string())
        }
        NativeQuery::GetSyncCursor { dataset } => {
            let cursor = get_sync_cursor(conn, dataset).map_err(|e| e.to_string())?;
            serde_json::to_value(cursor).map_err(|e| e.to_string())
        }
    }
}
