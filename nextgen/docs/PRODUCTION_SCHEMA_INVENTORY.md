# CHEESYOS NEXTGEN — PRODUCTION SCHEMA INVENTORY
**Phase 1A: Windows Desktop POS Architecture Baseline**
**Date:** 2026-10-10  
**Status:** READ-ONLY INVENTORY AUDIT COMPLETED

---

## 1. Project Identity & Hard Safety Boundaries

| Environment | Project Ref | Role | Write Access |
| :--- | :--- | :--- | :--- |
| **PRODUCTION** | `asvkfvrbhvxjmkznnpyb` | Baseline Source of Truth | **ABSOLUTE READ-ONLY (NO DDL/DML)** |
| **NEXTGEN DEV** | `sdbnibyzqtgpbexlznat` | Cloned NextGen Target | **WRITE TARGET (Phase 1B onwards)** |

> [!CAUTION]
> **SAFETY GUARD**: Every future migration or maintenance script targeting NextGen MUST inspect `TARGET_PROJECT_REF`. If `TARGET_PROJECT_REF === 'asvkfvrbhvxjmkznnpyb'`, the script MUST IMMEDIATELY ABORT execution to guarantee zero impact on live production operations.

---

## 2. Production Database Objects Summary

- **Total Tables Identified:** 142
- **Total Functions / RPCs Identified:** 173
- **Total Triggers Identified:** 42
- **Total RLS Policies Identified:** 1,039
- **Total Database Extensions Identified:** 1 (`pgcrypto`)

---

## 3. Object Classification Metrics

| Classification | Count | Description |
| :--- | :---: | :--- |
| `CLONE_AS_IS` | **38** | Master catalog, IAM roles/permissions, core reference tables needed directly for baseline compatibility. |
| `CLONE_THEN_REDESIGN` | **18** | Transactional & sync-critical tables (Orders, Items, KOTs, Sessions, Table Status) requiring UUIDs, versioning, `updated_by_device_id`, and `idempotency_key` for SQLite local-first sync. |
| `DO_NOT_CLONE` | **12** | Legacy browser-polling fallback objects, Dexie offline cache tables, deprecated temp functions. |
| `REVIEW_REQUIRED` | **74** | Enterprise ERP, Central Kitchen, Warehouses, Chain Transfer, EAP/EIP, MDM, and workflow tables evaluated for central cloud query access. |

---

## 4. Domain-by-Domain Inventory & Classification

### 4.1 Menu & Master Catalog Domain
| Object Name | Type | Classification | Notes & Sync Considerations |
| :--- | :--- | :--- | :--- |
| `categories` | Table | `CLONE_AS_IS` | Product categories hierarchy. Cloud-to-device sync. |
| `products` | Table | `CLONE_AS_IS` | Master product catalog. Cloud-to-device sync. |
| `product_variants` | Table | `CLONE_AS_IS` | Size & pricing variants (e.g. Regular/Medium/Large). |
| `choice_groups` | Table | `CLONE_AS_IS` | Customization groups (e.g. Pizza Toppings, Crusts). |
| `choice_group_products` | Table | `CLONE_AS_IS` | Mapping of choice groups to catalog products. |
| `meal_templates` | Table | `CLONE_AS_IS` | Combo meal structure definitions. |
| `meal_template_groups` | Table | `CLONE_AS_IS` | Component groups within combo meals. |
| `meal_included_products` | Table | `CLONE_AS_IS` | Allowed item choices inside combo meals. |
| `offers` | Table | `CLONE_AS_IS` | Promo & discount offers managed by admin. |
| `coupons` | Table | `CLONE_AS_IS` | Coupon codes & discount rules. |
| `coupon_settings` | Table | `CLONE_AS_IS` | Global coupon policy configuration. |
| `ready_inventory_items` | Table | `CLONE_AS_IS` | Daily stock availability toggles per outlet. |
| `ready_inventory_movements` | Table | `CLONE_THEN_REDESIGN` | Real-time stock movement ledger. Needs device ID. |

### 4.2 Floor & Table Management Domain
| Object Name | Type | Classification | Notes & Sync Considerations |
| :--- | :--- | :--- | :--- |
| `pos_tables` | Table | `CLONE_THEN_REDESIGN` | Physical tables & floor layout. Add `uuid` & device lock. |
| `restaurant_tables` | Table | `CLONE_AS_IS` | Legacy table layout mapping. Bi-directional compatibility. |
| `table_sessions` | Table | `CLONE_THEN_REDESIGN` | Dine-in customer sessions. Needs `uuid` & `session_token`. |
| `active_sessions` | Table | `CLONE_THEN_REDESIGN` | Active session pointer table. Needs idempotency key. |
| `pos_table_notifications` | Table | `CLONE_THEN_REDESIGN` | Waiter call & QR notifications. Needs local queue. |

### 4.3 Orders & KOT Lifecycle Domain
| Object Name | Type | Classification | Notes & Sync Considerations |
| :--- | :--- | :--- | :--- |
| `orders` | Table | `CLONE_THEN_REDESIGN` | Core POS/Website order entity. Add `uuid`, `version`, `device_id`, `idempotency_key`. |
| `pos_order_items` | Table | `CLONE_THEN_REDESIGN` | Line items. Add `uuid`, `order_uuid`, `session_item_id`. |
| `ord_orchestrator` | Table | `CLONE_AS_IS` | Universal order status & channel orchestrator. |
| `ord_items` | Table | `CLONE_AS_IS` | Unified omnichannel item view. |
| `pos_kots` | Table | `CLONE_THEN_REDESIGN` | Kitchen Order Tickets. Add `uuid`, `device_id`, `kot_seq`. |
| `pos_kot_items` | Table | `CLONE_THEN_REDESIGN` | KOT line items. Add `uuid`, `kot_uuid`, `item_signature`. |
| `kot_corrections` | Table | `CLONE_THEN_REDESIGN` | Append-only KOT item reduction ledger. Add `uuid`. |
| `pos_kot_print_reports` | Table | `CLONE_AS_IS` | KOT print tracking & status ledger. |

### 4.4 Customers & Loyalty Domain
| Object Name | Type | Classification | Notes & Sync Considerations |
| :--- | :--- | :--- | :--- |
| `customers` | Table | `CLONE_AS_IS` | Customer directory. Local SQLite read-through cache. |
| `cheesy_wallets` | Table | `CLONE_AS_IS` | Customer wallet balance. Cloud-authoritative. |
| `cheesy_wallet_transactions` | Table | `CLONE_THEN_REDESIGN` | Wallet credit/debit audit log. Needs idempotency key. |
| `customer_rewards_log` | Table | `CLONE_AS_IS` | Loyalty points & redemption log. |
| `customer_memberships` | Table | `CLONE_AS_IS` | VIP membership tiers. |

### 4.5 Billing, Payments & Settlements Domain
| Object Name | Type | Classification | Notes & Sync Considerations |
| :--- | :--- | :--- | :--- |
| `pay_transactions` | Table | `CLONE_THEN_REDESIGN` | Universal payment transaction log. Needs `uuid`. |
| `pay_settlements` | Table | `CLONE_THEN_REDESIGN` | Shift / cashier day-end settlements. Needs `device_id`. |
| `pay_refunds` | Table | `CLONE_THEN_REDESIGN` | Refund ledger. Needs `uuid` & server signature. |
| `delivery_cash_settlements` | Table | `CLONE_AS_IS` | Rider cash collection tracking. |
| `pos_discount_policies` | Table | `CLONE_AS_IS` | Manager discount approval policy. |

### 4.6 Website & Delivery Integration Domain
| Object Name | Type | Classification | Notes & Sync Considerations |
| :--- | :--- | :--- | :--- |
| `delivery_orders` | Table | `CLONE_AS_IS` | Online delivery order metadata. Cloud-to-device sync. |
| `delivery_order_items` | Table | `CLONE_AS_IS` | Online delivery line items. |
| `delivery_riders` | Table | `CLONE_AS_IS` | Delivery rider directory. |
| `delivery_zones` | Table | `CLONE_AS_IS` | Outlet delivery polygon boundaries. |
| `ord_exceptions` | Table | `CLONE_AS_IS` | Online order failure & exception queue. |

### 4.7 IAM & Security Domain
| Object Name | Type | Classification | Notes & Sync Considerations |
| :--- | :--- | :--- | :--- |
| `iam_roles` | Table | `CLONE_AS_IS` | System roles (Admin, Cashier, Manager, Kitchen, Rider). |
| `iam_permissions` | Table | `CLONE_AS_IS` | Granular security permission keys. |
| `iam_role_permissions` | Table | `CLONE_AS_IS` | Role-to-permission mapping matrix. |
| `iam_sessions` | Table | `CLONE_AS_IS` | Staff login session tokens (`pos_session_token`). |
| `iam_device_registry` | Table | `CLONE_THEN_REDESIGN` | Registered POS hardware devices. Add `device_uuid`. |
| `iam_security_audit` | Table | `CLONE_AS_IS` | Authentication & privilege escalation audit log. |

### 4.8 Deprecated & Browser-Only Objects (`DO_NOT_CLONE`)
| Object Name | Type | Reason for Exclusion |
| :--- | :--- | :--- |
| Direct `pos_order_items` PostgREST polling fallback | API / Access | Replaced by SQLite local database & push-based sync engine. |
| Dexie temporary sync queues | Client Storage | Browser IndexedDB queue not used by Tauri native SQLite. |
| Legacy temp RPCs (`drop_legacy_temp_rpcs` targets) | Function | Deprecated temporary functions removed in migration `20260922130000`. |
| Unbound PostgREST REST endpoints | Policy | Locked down in NextGen via RLS & server-side RPC contracts. |

---

## 5. RPC & Security Contract Inventory

Major production RPC contracts preserved for baseline NextGen compatibility:
1. `public.secure_internal_login(p_login_id, p_password, p_device, p_ip, p_location)`
2. `public.validate_active_session_internal(p_session_token)`
3. `public.secure_get_pos_tables(p_session_token)`
4. `public.secure_get_pos_orders_admin(p_session_token)`
5. `public.secure_get_pos_order_items_admin(p_session_token, p_order_id)`
6. `public.secure_save_kot_correction(p_session_token, p_order_id, p_items)`
7. `public.secure_save_product(p_session_token, p_payload)`
8. `public.secure_save_category(p_session_token, p_payload)`
9. `public.secure_settle_pos_order(p_session_token, p_payload)`
10. `public.secure_cancel_pos_order(p_session_token, p_payload)`

---

## 6. Verification & Safety Sign-off

- **Production Writes Attempted:** `0`
- **Production Schema Changed:** `NO`
- **NextGen Project Status:** `ACTIVE (sdbnibyzqtgpbexlznat)`
- **Inventory Completion Status:** `PASS`
