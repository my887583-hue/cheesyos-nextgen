# CHEESYOS NEXTGEN — WINDOWS POS SYNC CONTRACT (FINAL SPECIFICATION)

**Status**: FROZEN SYNC SPECIFICATION (PHASE 1.2 COMPLETE)  
**Scope**: Windows POS Local SQLite Outbox & Cloud Sync Engine Protocol

---

## 1. PRIMARY IDENTIFIERS & DISPLAY NUMBERS

To guarantee collision-free offline synchronization across multiple POS terminals:
1. **Database Identity**: **UUIDv4 (`id`)** is the primary key for all syncable entities (`orders`, `order_items`, `bills`, `payments`, `pos_kots`, `kot_items`, `kot_corrections`).
2. **Display Identity**: Human-readable strings (`display_number`, `bill_number`, `kot_number`) are stored as separate display columns and are **NEVER** used as database primary keys or foreign keys.

---

## 2. OFFLINE BILL NUMBERING STRATEGY

Windows POS prints fiscal bills while 100% offline without network latency or cloud sequence locks.

### DEVICE-PREFIXED BILL NUMBER FORMAT:
```text
CB-{TERMINAL_CODE}-{LOCAL_SEQUENCE}
Example: CB-K01-000123
```

### REQUIREMENTS & GUARANTEES:
- Each registered POS terminal is assigned a stable terminal short code (e.g., `K01`, `K02`).
- Local SQLite tracks `local_bill_seq` integer sequence per terminal.
- **Zero Collision Guarantee**: Terminal code prefix ensures `CB-K01-000123` and `CB-K02-000123` are distinct human bill numbers.
- **Offline Printable**: Generated instantly at billing time without cloud RPC calls.
- **Stable Identity**: Bill number string remains unchanged when pushed to Supabase Cloud during outbox sync.

---

## 3. DATA CLASSIFICATION MATRIX

| Classification | Storage Location | Strategy & Behavior | Entities Included |
| :--- | :--- | :--- | :--- |
| **LOCAL-FIRST** | Local SQLite + Outbox Queue | Written to local SQLite first. Outbox worker pushes to Cloud immediately when online. | `orders`, `order_items`, `table_sessions`, `pos_kots`, `kot_items`, `kot_corrections`, `bills`, `payments` |
| **CLOUD-FIRST** | Cloud Supabase | Written directly to Cloud via RPC. Not editable offline. | `spin_campaigns`, `spin_redemptions`, `inventory_movements`, `customer_addresses` |
| **SYNCED** | SQLite & Supabase | Bi-directional synchronization with delta updates (`updated_at`). | `customers`, `pos_tables`, `inventory_lite` |
| **CACHED** | Local SQLite (Read-Only) | Pulled from Cloud on startup / delta. Read offline. | `categories`, `products`, `product_variants`, `offers_banners`, `staff_profiles` |

---

## 4. LOCAL SQLITE OUTBOX SCHEMA

All local offline writes generate an entry in the local SQLite table `sync_outbox`:

```sql
CREATE TABLE sync_outbox (
  outbox_id TEXT PRIMARY KEY,       -- UUIDv4 generated locally
  entity_type TEXT NOT NULL,         -- 'order', 'kot', 'bill', 'payment', 'customer'
  entity_id TEXT NOT NULL,           -- Canonical UUID of entity
  operation TEXT NOT NULL,           -- 'INSERT', 'UPDATE', 'UPSERT'
  payload TEXT NOT NULL,             -- JSON string of entity data
  idempotency_key TEXT UNIQUE,       -- Ensures single execution on server
  device_id TEXT NOT NULL,           -- Unique identifier of POS terminal
  status TEXT DEFAULT 'pending',     -- 'pending', 'syncing', 'synced', 'failed'
  retry_count INTEGER DEFAULT 0,
  last_error TEXT,
  created_at TEXT NOT NULL,
  synced_at TEXT
);
```

### OUTBOX STATE TRANSITION:
```text
[ Local Write ]  --->  Insert to sync_outbox (status = 'pending')
                              │
                              ▼
                       Sync Engine Worker
                              │
                  (Check Network Connection)
                   ├── Online  ---> status = 'syncing' ---> Push to Supabase RPC
                   │                                          │
                   │                                          ├── Success ---> status = 'synced'
                   │                                          └── Failure ---> Retry Count++, Backoff
                   └── Offline ---> Remain 'pending'
```

---

## 5. SYNCABLE ENTITY CONTRACT & CONFLICT HANDLING

1. **Required Sync Fields**:
   - `id` (UUIDv4)
   - `created_at` (ISO timestamp)
   - `updated_at` (ISO timestamp)
   - `device_id` (Terminal ID string)
   - `sync_status` (`pending` | `synced` | `failed`)
   - `idempotency_key` (UUID string)
2. **Server Idempotency**: Push RPCs (e.g. `secure_sync_pos_order`) verify `idempotency_key`. Duplicate submissions return the existing record without duplicate insertion.
3. **Conflict Resolution Rules**:
   - **Dine-in Orders & Billing**: **Local POS Terminal Authority**. POS offline modifications take precedence.
   - **Catalog & Prices**: **Cloud Authority**. Cloud changes overwrite local cache.
   - **Customers**: **Last-Write-Wins (Timestamp based)** using `updated_at`.
