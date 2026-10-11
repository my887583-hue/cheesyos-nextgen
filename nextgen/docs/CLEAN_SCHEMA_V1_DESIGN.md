# CHEESYOS NEXTGEN — CLEAN DATABASE SCHEMA V1 DESIGN (FINAL LOGICAL SPECIFICATION)

**Status**: FROZEN LOGICAL SCHEMA SPECIFICATION (PHASE 1.2 COMPLETE — DO NOT EXECUTE SQL YET)  
**Target Database**: NextGen Supabase (`sdbnibyzqtgpbexlznat`) & Windows POS SQLite  
**Design Principle**: SMALLEST SAFE SCHEMA (20 Canonical Tables)

---

## 1. CANONICAL V1 TABLE CATALOG (20 TABLES)

Every table proposed for NextGen V1 is explicitly justified below with primary key strategy, important fields, writers, readers, SQLite role, and sync requirements.

---

### TABLE 1: `categories`
- **PURPOSE**: Menu category hierarchy (e.g., Pizza, Burgers, Beverages, Desserts).
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id`)
- **IMPORTANT_FIELDS**: `id`, `name`, `slug`, `display_order`, `is_active`, `created_at`, `updated_at`
- **WRITERS**: Admin
- **READERS**: Admin, Windows POS, Web POS, Website, QR Menu
- **WINDOWS_SQLITE_ROLE**: Read-Only Local Cache
- **SYNC_REQUIREMENT**: Cloud -> Local (Pull on startup / delta)
- **WHY_REQUIRED**: Essential navigation hierarchy for menu browsing across all sales channels.

---

### TABLE 2: `products`
- **PURPOSE**: Master catalog items, standalone sellable products, beverages, dips, and combos.
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id`)
- **IMPORTANT_FIELDS**: `id`, `category_id`, `name`, `description`, `image_url`, `base_price`, `is_available`, `tax_rate`, `created_at`, `updated_at`
- **WRITERS**: Admin
- **READERS**: Admin, Windows POS, Web POS, Website, QR Menu
- **WINDOWS_SQLITE_ROLE**: Read-Only Local Cache
- **SYNC_REQUIREMENT**: Cloud -> Local (Pull on startup / delta)
- **WHY_REQUIRED**: Core item catalog entity required for display, pricing, and order creation.

---

### TABLE 3: `product_variants`
- **PURPOSE**: Item size and flavor variations (e.g., Regular/Medium/Large, Cold Coffee flavors).
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id`)
- **IMPORTANT_FIELDS**: `id`, `product_id`, `variant_name`, `price_override`, `is_available`, `created_at`
- **WRITERS**: Admin
- **READERS**: Admin, Windows POS, Web POS, Website, QR Menu
- **WINDOWS_SQLITE_ROLE**: Read-Only Local Cache
- **SYNC_REQUIREMENT**: Cloud -> Local (Pull on startup / delta)
- **WHY_REQUIRED**: Handles basic product customization without complex modifier/BOM engines.

---

### TABLE 4: `customers`
- **PURPOSE**: Customer profiles, mobile identity, and account timestamps.
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id`)
- **IMPORTANT_FIELDS**: `id`, `phone`, `full_name`, `email`, `is_active`, `created_at`, `updated_at`
- **WRITERS**: POS Cashier, Website Auth, Admin
- **READERS**: POS (Customer 360 Lookup), Admin, Website, QR Menu
- **WINDOWS_SQLITE_ROLE**: Cached Read/Write Copy
- **SYNC_REQUIREMENT**: Bi-directional (Local outbox push -> Cloud)
- **WHY_REQUIRED**: Essential for cashier lookup, mobile identity, and Customer 360 recency metrics.

---

### TABLE 5: `customer_addresses`
- **PURPOSE**: Saved delivery addresses linked to customer profiles for website delivery.
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id`)
- **IMPORTANT_FIELDS**: `id`, `customer_id`, `address_label`, `street_address`, `city`, `latitude`, `longitude`, `is_default`, `created_at`
- **WRITERS**: Website, Customer, POS
- **READERS**: Website, POS, Admin
- **WINDOWS_SQLITE_ROLE**: Cached Read-Only Copy
- **SYNC_REQUIREMENT**: Cloud -> Local (Pull)
- **WHY_REQUIRED**: Required for website delivery checkout and Google Maps geocoded delivery coordinates.

---

### TABLE 6: `orders`
- **PURPOSE**: Master canonical order header for Dine-In, Takeaway, Delivery, and Website transactions.
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id`)
- **IMPORTANT_FIELDS**: `id`, `display_number`, `channel` (`POS`|`WEBSITE`), `order_type` (`DINE_IN`|`TAKEAWAY`|`DELIVERY`|`PICKUP`), `customer_id`, `table_session_id`, `status`, `subtotal`, `tax_total`, `discount_total`, `delivery_charge`, `grand_total`, `device_id`, `created_at`, `updated_at`
- **WRITERS**: POS (Windows/Web), Website RPC (`secure_create_order`)
- **READERS**: POS, Admin, Website, Customer
- **WINDOWS_SQLITE_ROLE**: Full Local Copy
- **SYNC_REQUIREMENT**: Bi-directional (Outbox push -> Cloud)
- **WHY_REQUIRED**: Unifies POS and Website orders into one canonical header table.

---

### TABLE 7: `order_items`
- **PURPOSE**: Line items for each order, capturing exact unit price, tax, and discount snapshots.
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id`)
- **IMPORTANT_FIELDS**: `id`, `order_id`, `product_id`, `variant_id`, `product_name`, `unit_price`, `quantity`, `tax_rate`, `discount_amount`, `line_total`, `notes`, `created_at`
- **WRITERS**: POS (Windows/Web), Website RPC
- **READERS**: POS, Admin, Website, Customer
- **WINDOWS_SQLITE_ROLE**: Full Local Copy
- **SYNC_REQUIREMENT**: Bi-directional (Outbox push -> Cloud)
- **WHY_REQUIRED**: Required for item-level billing, KOT generation, price immutability, and product analytics.

---

### TABLE 8: `pos_tables`
- **PURPOSE**: Physical floor layout tables, seating capacity, and table numbers.
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id`)
- **IMPORTANT_FIELDS**: `id`, `table_number`, `section`, `capacity`, `is_active`, `created_at`
- **WRITERS**: Admin, POS
- **READERS**: POS (Windows/Web), Admin
- **WINDOWS_SQLITE_ROLE**: Full Local Copy
- **SYNC_REQUIREMENT**: Bi-directional
- **WHY_REQUIRED**: Required for POS dine-in floor layout display and seating selection.

---

### TABLE 9: `table_sessions`
- **PURPOSE**: Active dine-in seating session tracking, guest count, and order association.
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id`)
- **IMPORTANT_FIELDS**: `id`, `table_id`, `current_order_id`, `guest_count`, `session_status` (`open`|`billed`|`closed`), `opened_at`, `closed_at`
- **WRITERS**: POS (Windows/Web)
- **READERS**: POS, Admin
- **WINDOWS_SQLITE_ROLE**: Full Local Copy
- **SYNC_REQUIREMENT**: Bi-directional (Outbox push -> Cloud)
- **WHY_REQUIRED**: Tracks occupied running tables vs available tables on POS floor.

---

### TABLE 10: `pos_kots`
- **PURPOSE**: Kitchen Order Ticket (KOT) dispatch headers and sequence logs.
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id`)
- **IMPORTANT_FIELDS**: `id`, `order_id`, `kot_number`, `device_id`, `status` (`printed`|`cancelled`), `printed_at`
- **WRITERS**: POS (Windows/Web)
- **READERS**: POS, Admin
- **WINDOWS_SQLITE_ROLE**: Full Local Copy
- **SYNC_REQUIREMENT**: Local -> Cloud (Push Outbox)
- **WHY_REQUIRED**: Essential operational ticket dispatch record for kitchen printing.

---

### TABLE 11: `kot_items`
- **PURPOSE**: Snapshot of exact items and quantities dispatched on a specific KOT.
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id`)
- **IMPORTANT_FIELDS**: `id`, `kot_id`, `product_id`, `variant_id`, `product_name`, `quantity`, `notes`
- **WRITERS**: POS (Windows/Web)
- **READERS**: POS, Admin
- **WINDOWS_SQLITE_ROLE**: Full Local Copy
- **SYNC_REQUIREMENT**: Local -> Cloud (Push Outbox)
- **WHY_REQUIRED**: Guarantees exact historical record of kitchen dispatches even if orders are later modified.

---

### TABLE 12: `kot_corrections`
- **PURPOSE**: Immutable audit ledger for item cancellations and quantity reductions after KOT print.
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id`)
- **IMPORTANT_FIELDS**: `id`, `order_id`, `kot_id`, `product_name`, `cancelled_qty`, `reason`, `authorized_by_staff_id`, `created_at`
- **WRITERS**: POS (Manager Auth required)
- **READERS**: POS, Admin
- **WINDOWS_SQLITE_ROLE**: Full Local Copy
- **SYNC_REQUIREMENT**: Local -> Cloud (Push Outbox)
- **WHY_REQUIRED**: Mandatory security audit ledger to detect and prevent cashier void fraud.

---

### TABLE 13: `bills`
- **PURPOSE**: Master fiscal invoice summary, tax totals (CGST/SGST), discount totals, and bill numbers.
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id`)
- **IMPORTANT_FIELDS**: `id`, `order_id`, `bill_number` (Device-prefixed e.g. `CB-K01-000123`), `subtotal`, `cgst_total`, `sgst_total`, `discount_total`, `grand_total`, `payment_status`, `finalized_at`, `device_id`
- **WRITERS**: POS (Windows/Web)
- **READERS**: POS, Admin, Customer
- **WINDOWS_SQLITE_ROLE**: Full Local Copy
- **SYNC_REQUIREMENT**: Local -> Cloud (Push Outbox)
- **WHY_REQUIRED**: Fiscal billing compliance, bill printing, and financial accounting.

---

### TABLE 14: `payments`
- **PURPOSE**: Cashier payment settlement records, payment mode split (Cash/UPI/Card), and confirmation details.
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id`)
- **IMPORTANT_FIELDS**: `id`, `bill_id`, `order_id`, `payment_mode` (`CASH`|`UPI`|`CARD`|`OTHER`), `amount_paid`, `confirmed_by_staff_id`, `confirmed_at`, `notes`
- **WRITERS**: POS Cashier Settlement, Website Payment Webhook
- **READERS**: POS, Admin
- **WINDOWS_SQLITE_ROLE**: Full Local Copy
- **SYNC_REQUIREMENT**: Bi-directional (Outbox push -> Cloud)
- **WHY_REQUIRED**: Cash drawer reconciliation, auditability, and payment breakdown reports.

---

### TABLE 15: `inventory_lite`
- **PURPOSE**: Current stock counts for directly countable ready-to-use items (beverages, dips, desserts).
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id`)
- **IMPORTANT_FIELDS**: `id`, `product_id`, `current_stock`, `low_stock_threshold`, `is_tracked`, `updated_at`
- **WRITERS**: Admin, POS Stock Deduction RPC
- **READERS**: POS, Admin
- **WINDOWS_SQLITE_ROLE**: Cached Stock Copy
- **SYNC_REQUIREMENT**: Bi-directional
- **WHY_REQUIRED**: Implements Inventory Lite requirement without raw material/BOM complexity.

---

### TABLE 16: `inventory_movements`
- **PURPOSE**: Audit log of stock refills, sales deductions, manual removals, and adjustments.
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id`)
- **IMPORTANT_FIELDS**: `id`, `product_id`, `movement_type` (`SALE`|`CANCEL_RESTORE`|`MANUAL_ADD`|`MANUAL_REMOVE`|`ADJUSTMENT`), `quantity_change`, `created_by`, `created_at`
- **WRITERS**: Admin, POS Stock RPC
- **READERS**: Admin
- **WINDOWS_SQLITE_ROLE**: None (Cloud Only)
- **SYNC_REQUIREMENT**: Cloud Only
- **WHY_REQUIRED**: Inventory audit log to detect stock discrepancies and unauthorized manual stock changes.

---

### TABLE 17: `offers_banners`
- **PURPOSE**: Unified promotional banners, coupons, start/end dates, and surface targets (`Website`/`QR`).
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id`)
- **IMPORTANT_FIELDS**: `id`, `title`, `image_url`, `coupon_code`, `discount_type`, `discount_value`, `min_order_value`, `target_surface` (`WEBSITE`|`QR_MENU`|`BOTH`), `start_date`, `end_date`, `is_active`, `display_order`, `destination_product_id`, `created_at`
- **WRITERS**: Admin
- **READERS**: Website, QR Menu, POS, Admin
- **WINDOWS_SQLITE_ROLE**: Read-Only Local Cache
- **SYNC_REQUIREMENT**: Cloud -> Local (Pull)
- **WHY_REQUIRED**: Single unified promotional banner and simple coupon model across customer surfaces.

---

### TABLE 18: `staff_profiles`
- **PURPOSE**: User identities, roles, `has_pos_access`, `has_admin_access`, and credential metadata.
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id` — FK to `auth.users.id`)
- **IMPORTANT_FIELDS**: `id`, `full_name`, `phone`, `role`, `has_pos_access`, `has_admin_access`, `offline_pin_hash`, `is_active`, `created_at`, `updated_at`
- **WRITERS**: Admin
- **READERS**: Admin, Auth RPCs
- **WINDOWS_SQLITE_ROLE**: Read-Only Staff Profiles (PIN hashed)
- **SYNC_REQUIREMENT**: Cloud -> Local (Pull)
- **WHY_REQUIRED**: Required for app-specific authentication and RBAC authorization.

---

### TABLE 19: `spin_campaigns`
- **PURPOSE**: Spin & Win campaign rules, prize probabilities, and active dates.
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id`)
- **IMPORTANT_FIELDS**: `id`, `campaign_name`, `start_date`, `end_date`, `is_active`, `prizes_json`, `created_at`
- **WRITERS**: Admin
- **READERS**: Spin App, Admin
- **WINDOWS_SQLITE_ROLE**: None (Cloud Only)
- **SYNC_REQUIREMENT**: Cloud Only
- **WHY_REQUIRED**: Manages Spin & Win campaign rules cleanly without hardcoding probabilities.

---

### TABLE 20: `spin_redemptions`
- **PURPOSE**: Customer spin participation history, won prizes, and coupon redemption tracking.
- **PRIMARY_KEY_STRATEGY**: UUIDv4 (`id`)
- **IMPORTANT_FIELDS**: `id`, `campaign_id`, `customer_id`, `phone`, `prize_won`, `coupon_code`, `is_redeemed`, `spun_at`, `redeemed_at`
- **WRITERS**: Spin App RPC
- **READERS**: Spin App, Admin
- **WINDOWS_SQLITE_ROLE**: None (Cloud Only)
- **SYNC_REQUIREMENT**: Cloud Only
- **WHY_REQUIRED**: Tracks customer game participation and prevents single-user prize farming.

---

## 2. CANONICAL ENTITY RELATIONSHIP MAP

```text
  [categories] ──< [products] ──< [product_variants]
                      │
                      ├──────────< [order_items] >────────── [orders] ──< [bills] ──< [payments]
                      │                                        │            │
                      ├──────────< [inventory_lite]            ├──────< [pos_kots] ──< [kot_items]
                      │                                        │            │
                      └──────────< [inventory_movements]       ├──────< [kot_corrections]
                                                               │
  [customers] ──< [customer_addresses]                         └──────< [table_sessions] >── [pos_tables]
      │
      └──────────< [spin_redemptions] >── [spin_campaigns]

  [staff_profiles] (Auth & Access Enforcement) ────> [orders], [kot_corrections], [payments]
  [offers_banners] (Promotions & Banners) ────────> [Website / QR Menu]
```
