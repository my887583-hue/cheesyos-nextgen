/**
 * CHEESYOS NEXTGEN POS LOCAL — SQLITE SCHEMA DEFINITIONS
 * 
 * Target: Windows Offline-First POS Local Persistence & Durable Outbox Queue.
 * Uses integer minor units (Paise) for all local monetary columns.
 */

export const SCHEMA_VERSION = 4;

export const INITIAL_SCHEMA_SQL = `
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;


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
  version INTEGER NOT NULL DEFAULT 1,
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
  order_item_id TEXT,
  product_id TEXT NOT NULL,
  variant_id TEXT,
  product_name TEXT NOT NULL,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  notes TEXT,
  FOREIGN KEY (kot_id) REFERENCES pos_kots(id) ON DELETE CASCADE,
  FOREIGN KEY (order_item_id) REFERENCES order_items(id),
  FOREIGN KEY (product_id) REFERENCES products(id),
  FOREIGN KEY (variant_id) REFERENCES product_variants(id)
);

-- 11. KOT CORRECTIONS (Void Audit Log)
CREATE TABLE IF NOT EXISTS kot_corrections (
  id TEXT PRIMARY KEY,
  order_id TEXT NOT NULL,
  kot_id TEXT,
  kot_item_id TEXT,
  order_item_id TEXT,
  product_name TEXT NOT NULL,
  cancelled_qty INTEGER NOT NULL CHECK (cancelled_qty > 0),
  reason TEXT NOT NULL,
  authorized_by_staff_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  FOREIGN KEY (order_id) REFERENCES orders(id),
  FOREIGN KEY (kot_id) REFERENCES pos_kots(id),
  FOREIGN KEY (kot_item_id) REFERENCES kot_items(id),
  FOREIGN KEY (order_item_id) REFERENCES order_items(id)
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
`;

