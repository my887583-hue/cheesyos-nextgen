# CHEESYOS NEXTGEN — DATABASE CLONE PLAN
**Phase 1A: Production Baseline to NextGen Supabase Clone Strategy**
**Target Project:** `sdbnibyzqtgpbexlznat` (NextGen Dev)  
**Source Baseline:** `asvkfvrbhvxjmkznnpyb` (Production — Read Only)

---

## 1. Safety Guard & Execution Rule

```javascript
// Hard Safety Barrier in all NextGen scripts:
const PRODUCTION_PROJECT_REF = "asvkfvrbhvxjmkznnpyb";
const NEXTGEN_PROJECT_REF    = "sdbnibyzqtgpbexlznat";

if (TARGET_PROJECT_REF === PRODUCTION_PROJECT_REF) {
  throw new Error("[SAFETY VIOLATION] Execution aborted: Cannot target Production project 'asvkfvrbhvxjmkznnpyb'.");
}
```

---

## 2. Sectioned Migration Strategy

### A. SCHEMA (Phase 1B Execution)
- Extract clean DDL statements from `supabase/migrations/*.sql`.
- Apply table structures to NextGen `sdbnibyzqtgpbexlznat`.
- Integrate offline-first distributed columns (`uuid`, `version`, `updated_by_device_id`, `idempotency_key`, `device_timestamp`).

### B. FUNCTIONS / RPC (Phase 1B Execution)
- Deploy core security-hardened RPCs (`validate_active_session_internal`, `secure_internal_login`, `secure_get_pos_tables`, `secure_get_pos_orders_admin`, `secure_save_kot_correction`, `secure_save_product`, `secure_save_category`).
- All RPCs must enforce server-side session token validation.

### C. RLS & SECURITY POLICIES (Phase 1B Execution)
- Deploy default deny RLS policies on public schema tables.
- Grant explicit execution privileges to `authenticated` and `anon` roles for validated RPCs only.

### D. TRIGGERS (Phase 1B Execution)
- Deploy auto-updating `updated_at` timestamp triggers.
- Deploy audit logging triggers for operational credential changes & privilege escalations.

### E. EXTENSIONS (Phase 1B Execution)
- Enable `pgcrypto` extension on `sdbnibyzqtgpbexlznat` for `gen_random_uuid()` generation.

### F. MASTER DATA (Phase 1B Execution)
- Controlled seed of core catalog & setup data:
  - `categories`
  - `products` & `product_variants`
  - `choice_groups` & `choice_group_products`
  - `pos_tables` & floor layout
  - `offers` & `coupons`
  - `iam_roles` & `iam_permissions`

### G. TRANSACTIONAL DATA (EXCLUDED IN PHASE 1A/1B)
- **DO NOT COPY REAL PRODUCTION TRANSACTIONS**:
  - `orders` (`REAL_ORDER_DATA_EXPORTED=NO`)
  - `pos_order_items`
  - `pay_transactions` (`REAL_PAYMENT_DATA_EXPORTED=NO`)
  - `pay_settlements`
  - `pos_kots` & `kot_corrections`
- NextGen development will run on controlled synthetic test orders.

### H. CUSTOMER DATA (EXCLUDED IN PHASE 1A/1B)
- **DO NOT COPY REAL CUSTOMER DIRECTORY**:
  - `customers` (`REAL_CUSTOMER_DATA_EXPORTED=NO`)
  - `cheesy_wallets`
  - `cheesy_wallet_transactions`
- Synthetic mock customer records will be seeded for offline lookup testing.

---

## 3. Distributed ID & Conflict Analysis

### Problem Statement: Autoincrement Integer PKs in Offline POS
Production Supabase currently relies on autoincrement integer primary keys (`orders.id INT`, `pos_order_items.id BIGINT`, `pos_kots.id BIGINT`).
When multiple Windows Desktop POS terminals operate offline simultaneously:
- Terminal A creates local order `#101`.
- Terminal B creates local order `#101`.
- On reconnection, a database primary key collision occurs if integer IDs are used as primary identifiers.

### Resolution Strategy for Windows Desktop POS
1. **Dual Identity Schema**:
   - `id` (INTEGER / BIGINT): Retained for display compatibility & legacy API contracts.
   - `uuid` (UUID DEFAULT gen_random_uuid()): Introduced as the primary distributed identifier across SQLite and Supabase.
2. **Idempotent Queueing**:
   - `idempotency_key` (TEXT / UUID): Unique client-generated key per transaction attempt to prevent duplicate order submissions during network retries.

---

## 4. NextGen Column Enhancements for Sync Engine

Every offline-syncable table (`orders`, `pos_order_items`, `pos_kots`, `pos_kot_items`, `kot_corrections`, `table_sessions`, `pay_transactions`) will be augmented in NextGen with:

```sql
ALTER TABLE public.orders 
  ADD COLUMN IF NOT EXISTS uuid UUID DEFAULT gen_random_uuid() UNIQUE,
  ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1,
  ADD COLUMN IF NOT EXISTS updated_by_device_id TEXT,
  ADD COLUMN IF NOT EXISTS idempotency_key TEXT UNIQUE,
  ADD COLUMN IF NOT EXISTS device_timestamp TIMESTAMPTZ DEFAULT NOW();
```

---

## 5. Phase 1B Execution Readiness

- **Production Project Ref:** `asvkfvrbhvxjmkznnpyb` (Locked / Read-Only)
- **NextGen Project Ref:** `sdbnibyzqtgpbexlznat` (Active / Ready for DDL in Phase 1B)
- **Tauri Installed:** `NO`
- **SQLite Created:** `NO`
- **Next Step:** `SCHEMA_CLONE_TO_NEXTGEN` (Phase 1B)
